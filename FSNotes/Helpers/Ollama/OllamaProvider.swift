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

import Foundation

// MARK: - Provider

class OllamaProvider: AIProvider {
    private let host: String
    private let model: String
    /// MCP server queried for the `tools` schema list at request time
    /// and (Phase 2 follow-up slice 3) for tool dispatch when the
    /// model produces `tool_calls`. Defaults to `MCPServer.shared`;
    /// tests inject an isolated server with stub tools.
    let mcpServer: MCPServer

    init(host: String, model: String, mcpServer: MCPServer = .shared) {
        self.host = host
        self.model = model
        self.mcpServer = mcpServer
    }

    /// Build the URLRequest that `sendMessage` will fire. Exposed for unit tests
    /// so they can capture and assert the JSON body without a live server.
    ///
    /// `apiMessages` lets the continuation loop (slice 3) re-issue chat with
    /// the conversation extended by assistant `tool_calls` and `role: "tool"`
    /// results — those carry shapes the simple `[ChatMessage]` model can't
    /// represent. When `apiMessages` is nil, the standard system+user history
    /// is built from `messages`.
    func makeChatRequest(messages: [ChatMessage],
                         noteContent: String,
                         apiMessages: [[String: Any]]? = nil) throws -> URLRequest {
        guard let url = OllamaClient.chatURL(host: host) else {
            throw OllamaClientError.invalidHost(host)
        }

        let outgoingMessages: [[String: Any]]
        if let override = apiMessages {
            outgoingMessages = override
        } else {
            // System prompt mirrors the other providers — embed the active note content.
            let systemContent = ollamaSystemPrompt(noteContent: noteContent)
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
                     noteContent: String,
                     onToken: @escaping (String) -> Void,
                     onComplete: @escaping (Result<String, Error>) -> Void) {
        let request: URLRequest
        do {
            request = try makeChatRequest(messages: messages, noteContent: noteContent)
        } catch {
            onComplete(.failure(error))
            return
        }

        let parser = OllamaStreamParser(onToken: onToken, onComplete: onComplete)
        let delegate = OllamaStreamDelegate(parser: parser)
        let session = URLSession(configuration: .default,
                                 delegate: delegate,
                                 delegateQueue: nil)
        let task = session.dataTask(with: request)
        task.resume()
    }
}

// MARK: - System prompt

/// System prompt for Ollama. Same shape as the other providers: brief instructions +
/// the live note content. Phase 2 will extend this with MCP tool descriptions.
private func ollamaSystemPrompt(noteContent: String) -> String {
    return """
    You are a helpful writing assistant integrated into a note-taking app (FSNotes). \
    The user is editing a markdown note. You can help them review, edit, summarize, \
    translate, or transform the note content. When suggesting edits, provide the updated \
    text clearly. Be concise and helpful.

    Current note content:
    ---
    \(noteContent)
    ---
    """
}

// MARK: - NDJSON stream parser

/// Parses Ollama's NDJSON streaming response. Each line is a self-contained JSON
/// object. Unlike SSE there's no `data: ` prefix and no `[DONE]` sentinel — the
/// terminating object has `done: true`.
final class OllamaStreamParser {
    private var buffer = ""
    private var fullResponse = ""
    private var hasCompleted = false
    private let onToken: (String) -> Void
    private let onComplete: (Result<String, Error>) -> Void

    init(onToken: @escaping (String) -> Void,
         onComplete: @escaping (Result<String, Error>) -> Void) {
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
            onComplete(.success(fullResponse))
        }
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

        if let message = json["message"] as? [String: Any],
           let content = message["content"] as? String,
           !content.isEmpty {
            fullResponse += content
            DispatchQueue.main.async { [onToken] in
                onToken(content)
            }
        }

        if let done = json["done"] as? Bool, done {
            hasCompleted = true
            let response = fullResponse
            DispatchQueue.main.async { [onComplete] in
                onComplete(.success(response))
            }
        }
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
