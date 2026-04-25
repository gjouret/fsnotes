//
//  OllamaProvider.swift
//  FSNotes
//
//  AIProvider conformer that streams from a local Ollama server via /api/chat.
//  Mirrors the AnthropicProvider / OpenAIProvider style: a request-builder helper
//  that's testable in isolation, plus a URLSessionDataDelegate that parses the
//  streaming response. Ollama uses NDJSON (one JSON object per line) instead of
//  SSE, so the parser is its own type rather than an extra format on SSEDelegate.
//
//  Phase 2 follow-up (slices 1-3) wires this into MCPServer for tool calling:
//    1. Tool schemas go out in every request body.
//    2. The streamed response may contain `message.tool_calls` instead of (or
//       in addition to) text — the parser buffers them and reports back via
//       `OllamaStreamOutcome.toolCalls`.
//    3. `sendMessage` runs a continuation loop: on tool_calls it dispatches via
//       `MCPServer.handleToolCalls`, appends `role: "tool"` results to the
//       conversation, and re-issues chat. Loop terminates when the model
//       produces text instead of tool_calls (or after MAX_TOOL_ROUNDS).
//

import Foundation

// MARK: - Provider

class OllamaProvider: AIProvider {
    private let host: String
    private let model: String
    /// MCP server queried for the `tools` schema list at request time
    /// and for tool dispatch when the model produces `tool_calls`.
    /// Defaults to `MCPServer.shared`; tests inject an isolated server
    /// with stub tools.
    let mcpServer: MCPServer
    /// URLSession factory. Default builds a real session per request.
    /// Tests inject a closure that returns a session bound to a
    /// mock-protocol class so they can serve canned NDJSON responses.
    private let sessionFactory: (URLSessionDelegate) -> URLSession

    /// Optional observer fired BEFORE a tool is dispatched. The chat
    /// panel uses this to render an in-flight tool-call bubble. Always
    /// invoked on the main queue.
    var onToolCallStarted: ((ToolCall) -> Void)?

    /// Optional observer fired AFTER a tool has produced a result
    /// (success or error). Fired on the main queue. The chat panel
    /// uses this to update the in-flight bubble with the outcome.
    var onToolCallCompleted: ((ToolCall, ToolOutput) -> Void)?

    /// Hard cap on tool-calling round trips per `sendMessage` call.
    /// 10 rounds is enough for any realistic chained-tool workflow
    /// (read → search → write → confirm) and small enough that a buggy
    /// model looping on the same call cannot wedge the chat panel.
    static let maxToolRounds = 10

    init(host: String,
         model: String,
         mcpServer: MCPServer = .shared,
         sessionFactory: ((URLSessionDelegate) -> URLSession)? = nil) {
        self.host = host
        self.model = model
        self.mcpServer = mcpServer
        if let factory = sessionFactory {
            self.sessionFactory = factory
        } else {
            self.sessionFactory = { delegate in
                URLSession(configuration: .default,
                           delegate: delegate,
                           delegateQueue: nil)
            }
        }
    }

    /// Build the URLRequest that `sendMessage` will fire. Exposed for unit tests
    /// so they can capture and assert the JSON body without a live server.
    ///
    /// `apiMessages` lets the continuation loop re-issue chat with the
    /// conversation extended by assistant `tool_calls` and `role: "tool"`
    /// results — those carry shapes the simple `[ChatMessage]` model can't
    /// represent. When `apiMessages` is nil, the standard system+user history
    /// is built from `messages`.
    func makeChatRequest(messages: [ChatMessage],
                         context: AIPromptContext,
                         apiMessages: [[String: Any]]? = nil) throws -> URLRequest {
        guard let url = OllamaClient.chatURL(host: host) else {
            throw OllamaClientError.invalidHost(host)
        }

        let outgoingMessages: [[String: Any]]
        if let override = apiMessages {
            outgoingMessages = override
        } else {
            // System prompt is the same shared text every provider sends.
            // See AIService.swift -> aiSystemPrompt.
            let systemContent = aiSystemPrompt(context, mcpServer: mcpServer)
            var msgs: [[String: Any]] = [
                ["role": "system", "content": systemContent]
            ]
            for msg in messages where msg.role != .system {
                msgs.append(["role": msg.role.rawValue, "content": msg.content])
            }
            outgoingMessages = msgs
        }

        // Phase 2 follow-up slice 1: the `tools` slot is now populated from
        // MCPServer.shared.toolSchemasForLLM(). When no tools are registered
        // the slot is an empty array, preserving the Phase 1 contract.
        let body: [String: Any] = [
            "model": model,
            "stream": true,
            "messages": outgoingMessages,
            "tools": mcpServer.toolSchemasForLLM()
        ]

        let jsonData: Data
        do {
            jsonData = try JSONSerialization.data(withJSONObject: body)
        } catch {
            throw AIError.serializationFailed
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData
        return request
    }

    func sendMessage(messages: [ChatMessage],
                     context: AIPromptContext,
                     onToken: @escaping (String) -> Void,
                     onComplete: @escaping (Result<String, Error>) -> Void) {
        // Build the seed conversation. The continuation loop mutates this
        // dictionary array as tool_calls and tool results come back.
        let systemContent = aiSystemPrompt(context, mcpServer: mcpServer)
        var conversation: [[String: Any]] = [
            ["role": "system", "content": systemContent]
        ]
        for msg in messages where msg.role != .system {
            conversation.append(["role": msg.role.rawValue, "content": msg.content])
        }

        runChatRound(conversation: conversation,
                     round: 1,
                     accumulatedText: "",
                     onToken: onToken,
                     onComplete: onComplete)
    }

    /// One chat round-trip plus, on `.toolCalls`, dispatch + recursion.
    /// `accumulatedText` carries any text emitted before a tool call so a
    /// final completion sees the whole assistant response.
    private func runChatRound(conversation: [[String: Any]],
                              round: Int,
                              accumulatedText: String,
                              onToken: @escaping (String) -> Void,
                              onComplete: @escaping (Result<String, Error>) -> Void) {
        let request: URLRequest
        do {
            // The conversation override carries the full system+user+tool
            // history; the empty messages/context here is intentional —
            // makeChatRequest only consults them when `apiMessages` is nil.
            request = try makeChatRequest(messages: [],
                                          context: AIPromptContext(),
                                          apiMessages: conversation)
        } catch {
            DispatchQueue.main.async { onComplete(.failure(error)) }
            return
        }

        let parser = OllamaStreamParser(onToken: onToken) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let err):
                onComplete(.failure(err))
            case .success(.text(let text)):
                let combined = accumulatedText + text
                onComplete(.success(combined))
            case .success(.toolCalls(let calls, let preamble)):
                // Hand off to the dispatcher; recursion happens inside.
                let combinedText = accumulatedText + preamble
                self.dispatchToolCallsAndContinue(
                    calls: calls,
                    conversation: conversation,
                    preamble: preamble,
                    round: round,
                    accumulatedText: combinedText,
                    onToken: onToken,
                    onComplete: onComplete
                )
            }
        }
        let delegate = OllamaStreamDelegate(parser: parser)
        let session = sessionFactory(delegate)
        let task = session.dataTask(with: request)
        task.resume()
    }

    /// Append the assistant tool_call message + role:"tool" results to the
    /// conversation, then re-run a chat round. Bumps `round`; if it
    /// exceeds `maxToolRounds`, surfaces an error instead of looping.
    private func dispatchToolCallsAndContinue(calls: [ParsedToolCall],
                                              conversation: [[String: Any]],
                                              preamble: String,
                                              round: Int,
                                              accumulatedText: String,
                                              onToken: @escaping (String) -> Void,
                                              onComplete: @escaping (Result<String, Error>) -> Void) {
        if round >= OllamaProvider.maxToolRounds {
            DispatchQueue.main.async {
                onComplete(.failure(AIError.apiError(
                    "Tool-calling exceeded \(OllamaProvider.maxToolRounds) rounds without a text response."
                )))
            }
            return
        }

        // Build the assistant message that records the tool_calls we received.
        // We round-trip Ollama's wire shape: each call carries function.name +
        // function.arguments; ids are echoed back so the model can correlate.
        var assistantMessage: [String: Any] = ["role": "assistant"]
        if !preamble.isEmpty {
            assistantMessage["content"] = preamble
        } else {
            assistantMessage["content"] = ""
        }
        assistantMessage["tool_calls"] = calls.map { call -> [String: Any] in
            var entry: [String: Any] = [
                "function": [
                    "name": call.name,
                    "arguments": call.arguments
                ]
            ]
            if !call.id.isEmpty {
                entry["id"] = call.id
            }
            return entry
        }
        var nextConversation = conversation
        nextConversation.append(assistantMessage)

        // Convert ParsedToolCall -> ToolCall so MCPServer can dispatch.
        let toolCalls = calls.map { call in
            ToolCall(id: call.id, name: call.name, arguments: call.arguments)
        }

        // Fire the started-observer for each call so the chat panel
        // can render in-flight bubbles before the tool runs.
        if let started = self.onToolCallStarted {
            DispatchQueue.main.async {
                for call in toolCalls {
                    started(call)
                }
            }
        }

        Task.detached { [weak self] in
            guard let self = self else { return }
            let results = await self.mcpServer.handleToolCalls(toolCalls)

            // Notify the completion observer per result. We zip on
            // index because handleToolCalls preserves order.
            if let completed = self.onToolCallCompleted {
                let pairs = Array(zip(toolCalls, results))
                DispatchQueue.main.async {
                    for (call, result) in pairs {
                        completed(call, result.output)
                    }
                }
            }

            // Append a role:"tool" message per result. Ollama matches them
            // back to the call by name (and tool_call_id when present).
            for result in results {
                var toolMessage: [String: Any] = [
                    "role": "tool",
                    "name": result.toolName,
                    "content": result.output.encodeAsJSONString()
                ]
                if !result.callID.isEmpty {
                    toolMessage["tool_call_id"] = result.callID
                }
                nextConversation.append(toolMessage)
            }

            self.runChatRound(conversation: nextConversation,
                              round: round + 1,
                              accumulatedText: accumulatedText,
                              onToken: onToken,
                              onComplete: onComplete)
        }
    }
}

// MARK: - Stream outcome types

/// One tool call pulled out of a streamed `message.tool_calls` array. The
/// shape mirrors `ToolCall` but is parser-internal so the parser stays free
/// of any MCP-layer dependency in tests that exercise it directly.
struct ParsedToolCall {
    let id: String
    let name: String
    let arguments: [String: Any]
}

/// What a complete NDJSON stream resolved to. Either a final text response
/// (model produced a content reply) or a batch of tool calls the client must
/// dispatch and feed back as `role: "tool"` messages.
enum OllamaStreamOutcome {
    /// Final text response. The string is the full accumulated content.
    case text(String)
    /// Model requested tool calls. `preamble` is any text streamed before
    /// the tool_calls were emitted (some models narrate before calling);
    /// it is preserved so the assistant message we echo back to Ollama
    /// carries the same content.
    case toolCalls([ParsedToolCall], preamble: String)
}

// MARK: - NDJSON stream parser

/// Parses Ollama's NDJSON streaming response. Each line is a self-contained JSON
/// object. Unlike SSE there's no `data: ` prefix and no `[DONE]` sentinel — the
/// terminating object has `done: true`.
final class OllamaStreamParser {
    private var buffer = ""
    private var fullResponse = ""
    private var pendingToolCalls: [ParsedToolCall] = []
    private var hasCompleted = false
    private let onToken: (String) -> Void
    private let onComplete: (Result<OllamaStreamOutcome, Error>) -> Void

    init(onToken: @escaping (String) -> Void,
         onComplete: @escaping (Result<OllamaStreamOutcome, Error>) -> Void) {
        self.onToken = onToken
        self.onComplete = onComplete
    }

    /// Feed a chunk of UTF-8 text. Partial lines are buffered until the next newline.
    func feed(_ text: String) {
        guard !hasCompleted else { return }
        buffer += text

        while let lineEnd = buffer.range(of: "\n") {
            let line = String(buffer[buffer.startIndex..<lineEnd.lowerBound])
            buffer = String(buffer[lineEnd.upperBound...])
            handleLine(line)
        }
    }

    /// Called by the URLSession delegate when the network task completes.
    /// If we haven't seen a `done: true` line, treat the connection close as success
    /// and return whatever we've accumulated.
    func finish(error: Error?) {
        guard !hasCompleted else { return }
        // Flush any trailing line without a newline.
        if !buffer.isEmpty {
            handleLine(buffer)
            buffer = ""
        }
        guard !hasCompleted else { return }
        hasCompleted = true
        if let error = error {
            onComplete(.failure(error))
        } else {
            onComplete(.success(currentOutcome()))
        }
    }

    private func currentOutcome() -> OllamaStreamOutcome {
        if !pendingToolCalls.isEmpty {
            return .toolCalls(pendingToolCalls, preamble: fullResponse)
        }
        return .text(fullResponse)
    }

    private func handleLine(_ rawLine: String) {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        // Error payloads from Ollama come back as `{"error": "..."}`.
        if let errMsg = json["error"] as? String {
            hasCompleted = true
            onComplete(.failure(AIError.apiError(errMsg)))
            return
        }

        if let message = json["message"] as? [String: Any] {
            // Text content — append and stream to the UI as before. Some
            // models emit empty content alongside tool_calls; skip empties.
            if let content = message["content"] as? String, !content.isEmpty {
                fullResponse += content
                DispatchQueue.main.async { [onToken] in
                    onToken(content)
                }
            }
            // Tool calls — buffer for dispatch on `done: true`. Any single
            // streamed line may carry one or more calls; multiple lines may
            // each carry partials, so we accumulate.
            if let calls = message["tool_calls"] as? [[String: Any]] {
                for call in calls {
                    if let parsed = parseToolCall(call) {
                        pendingToolCalls.append(parsed)
                    }
                }
            }
        }

        if let done = json["done"] as? Bool, done {
            hasCompleted = true
            let outcome = currentOutcome()
            DispatchQueue.main.async { [onComplete] in
                onComplete(.success(outcome))
            }
        }
    }

    /// Pull `id` (optional, synthesised if absent), `function.name`, and
    /// `function.arguments` out of one streamed tool_call entry. Returns nil
    /// when the shape is malformed enough that we can't even name the tool.
    /// Malformed `arguments` (string instead of object, missing entirely) are
    /// kept as an empty dict so MCPServer can still dispatch and the tool can
    /// surface a `.error` result the model can react to.
    private func parseToolCall(_ entry: [String: Any]) -> ParsedToolCall? {
        guard let function = entry["function"] as? [String: Any],
              let name = function["name"] as? String,
              !name.isEmpty else {
            return nil
        }
        let id: String
        if let explicit = entry["id"] as? String, !explicit.isEmpty {
            id = explicit
        } else {
            // Ollama's open-source models often omit ids; synthesise a stable
            // one so MCPServer can correlate calls with results.
            id = "call_\(UUID().uuidString.prefix(8))"
        }
        var arguments: [String: Any] = [:]
        if let dict = function["arguments"] as? [String: Any] {
            arguments = dict
        } else if let raw = function["arguments"] as? String,
                  let data = raw.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // Some model frontends serialize arguments as a JSON string; decode it.
            arguments = dict
        }
        return ParsedToolCall(id: id, name: name, arguments: arguments)
    }
}

// MARK: - URLSessionDataDelegate adapter

/// Tiny delegate that funnels bytes to the parser. Kept separate from the parser so
/// the parser can be unit-tested without setting up a URLSession.
final class OllamaStreamDelegate: NSObject, URLSessionDataDelegate {
    private let parser: OllamaStreamParser

    init(parser: OllamaStreamParser) {
        self.parser = parser
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        parser.feed(text)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        session.finishTasksAndInvalidate()
        parser.finish(error: error)
    }
}
