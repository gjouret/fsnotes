//
//  MCPServer.swift
//  FSNotes
//
//  In-process MCP (Model Context Protocol) server. Hosts the
//  registry of `MCPTool`s, dispatches tool calls coming from an LLM
//  provider, and holds a reference to the `AppBridge` so tools can
//  query open-editor state and notify the app after filesystem
//  writes.
//
//  See docs/AI.md "MCPServer" and "App Bridge" sections.
//
//  TODO Phase 2 follow-up: wire OllamaProvider into
//  MCPServer.handleToolCalls (the OllamaProvider streaming loop will
//  call `await MCPServer.shared.handleToolCalls(calls)` and feed the
//  resulting `[ToolResult]` back into the conversation as `tool`
//  role messages).
//
//  TODO Phase 2 follow-up: ViewController implements AppBridge.
//  Until that lands, `MCPServer.shared.appBridge` defaults to a
//  `NoOpAppBridge` so closed-note reads work and writes proceed
//  without coordination. Tests inject a stub bridge directly.
//

import Foundation

/// Errors specific to the MCP plumbing layer. Tool-execution failures
/// are surfaced as `ToolOutput.error`, not thrown. `MCPError` is for
/// problems the server itself detects (unknown tool name, malformed
/// argument shape) before a tool ever runs.
public enum MCPError: LocalizedError {
    case unknownTool(String)
    case malformedArguments(String)
    case storageRootUnavailable

    public var errorDescription: String? {
        switch self {
        case .unknownTool(let name):
            return "Unknown tool: \(name)"
        case .malformedArguments(let reason):
            return "Malformed tool arguments: \(reason)"
        case .storageRootUnavailable:
            return "FSNotes++ storage root is not configured"
        }
    }
}

/// In-process tool dispatcher. Singleton so providers can register a
/// shared toolset on startup, but tests can create their own
/// instance via `MCPServer(storageRoot:)` to isolate state.
public final class MCPServer {
    public static let shared = MCPServer()

    /// Root folder under which all note paths are resolved. Defaults
    /// to `UserDefaultsManagement.storageUrl`; tests override it via
    /// the initialiser.
    public var storageRoot: URL?

    /// Coordination protocol with the live app. Defaults to a no-op
    /// implementation; the real `ViewController` adopts this in a
    /// follow-up slice.
    public var appBridge: AppBridge = NoOpAppBridge()

    private var tools: [String: MCPTool] = [:]
    private let lock = NSLock()

    /// Designated initialiser. Tests pass an explicit `storageRoot`
    /// pointing at a temporary directory.
    public init(storageRoot: URL? = nil, appBridge: AppBridge? = nil) {
        if let root = storageRoot {
            self.storageRoot = root
        } else {
            #if !MCP_NO_USER_DEFAULTS
            self.storageRoot = UserDefaultsManagement.storageUrl
            #endif
        }
        if let bridge = appBridge {
            self.appBridge = bridge
        }
    }

    /// Register a tool. Subsequent registrations with the same name
    /// replace the previous one — useful for tests that swap a tool
    /// for a fixture.
    public func registerTool(_ tool: MCPTool) {
        lock.lock(); defer { lock.unlock() }
        tools[tool.name] = tool
    }

    /// Unregister a tool by name. No-op if the name is unknown.
    public func unregisterTool(named name: String) {
        lock.lock(); defer { lock.unlock() }
        tools.removeValue(forKey: name)
    }

    /// Snapshot of the registered tools.
    public var registeredTools: [MCPTool] {
        lock.lock(); defer { lock.unlock() }
        return Array(tools.values)
    }

    /// Look up a tool by name, or nil if not registered.
    public func tool(named name: String) -> MCPTool? {
        lock.lock(); defer { lock.unlock() }
        return tools[name]
    }

    /// Execute a batch of tool calls sequentially. Unknown tool names
    /// produce a `ToolOutput.error("Unknown tool: ...")` rather than
    /// throwing — the LLM gets a uniform shape back. Tools that
    /// throw are caught and reported the same way.
    public func handleToolCalls(_ calls: [ToolCall]) async -> [ToolResult] {
        var results: [ToolResult] = []
        results.reserveCapacity(calls.count)
        for call in calls {
            guard let tool = self.tool(named: call.name) else {
                results.append(ToolResult(
                    callID: call.id,
                    toolName: call.name,
                    output: .error("Unknown tool: \(call.name)")
                ))
                continue
            }
            let output = await tool.execute(input: call.arguments)
            results.append(ToolResult(callID: call.id, toolName: call.name, output: output))
        }
        return results
    }

    // MARK: - JSON tool-schema export

    /// Schema array suitable for the `tools` field of an Ollama or
    /// OpenAI chat-completions request. Each entry is
    /// `{"type": "function", "function": {name, description,
    /// parameters}}`.
    public func toolSchemasForLLM() -> [[String: Any]] {
        return registeredTools.map { tool in
            [
                "type": "function",
                "function": [
                    "name": tool.name,
                    "description": tool.description,
                    "parameters": tool.inputSchema
                ]
            ]
        }
    }
}
