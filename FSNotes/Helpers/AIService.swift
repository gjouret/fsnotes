//
//  AIService.swift
//  FSNotes
//
//  AI provider abstraction with streaming support for Claude and OpenAI APIs.
//

import Foundation

// MARK: - Data Models

struct ChatMessage {
    enum Role: String {
        case system, user, assistant
    }
    let role: Role
    let content: String
}

// MARK: - AI Provider Protocol

protocol AIProvider {
    func sendMessage(
        messages: [ChatMessage],
        context: AIPromptContext,
        onToken: @escaping (String) -> Void,
        onComplete: @escaping (Result<String, Error>) -> Void
    )
}

// MARK: - Prompt Context

/// Value type passed to every provider so the shared system prompt can
/// describe the user's current FSNotes++ state. The fields mirror the
/// spec template in `docs/AI.md` (lines 528-566). All optional fields
/// fall back to sensible defaults when no note is open.
public struct AIPromptContext {
    public let noteTitle: String?
    public let noteContent: String
    public let noteFolder: String?
    public let projectName: String?
    public let allTags: [String]
    public let editorMode: EditorMode
    public let isTextBundle: Bool

    public enum EditorMode: String {
        case wysiwyg = "WYSIWYG (Document model)"
        case source = "Source mode"
        case none = "No note open"
    }

    public init(noteTitle: String? = nil,
                noteContent: String = "",
                noteFolder: String? = nil,
                projectName: String? = nil,
                allTags: [String] = [],
                editorMode: EditorMode = .none,
                isTextBundle: Bool = false) {
        self.noteTitle = noteTitle
        self.noteContent = noteContent
        self.noteFolder = noteFolder
        self.projectName = projectName
        self.allTags = allTags
        self.editorMode = editorMode
        self.isTextBundle = isTextBundle
    }
}

// MARK: - Shared System Prompt

/// Renders the full system prompt mandated by `docs/AI.md` (lines
/// 528-566). The per-tool list is read from `MCPServer.shared` so when
/// Phase 5 adds or removes tools the prompt updates automatically.
internal func aiSystemPrompt(_ ctx: AIPromptContext,
                             mcpServer: MCPServer = .shared) -> String {
    let title = ctx.noteTitle?.isEmpty == false ? ctx.noteTitle! : "(no note open)"
    let folder = ctx.noteFolder?.isEmpty == false ? ctx.noteFolder! : "(none)"
    let project = ctx.projectName?.isEmpty == false ? ctx.projectName! : "(none)"
    let tags = ctx.allTags.isEmpty ? "(none)" : ctx.allTags.joined(separator: ", ")
    let storage = ctx.isTextBundle ? "TextBundle" : "Plain markdown"

    let tools = mcpServer.registeredTools.sorted { $0.name < $1.name }
    let toolLines: String
    if tools.isEmpty {
        toolLines = "- (no tools currently registered)"
    } else {
        toolLines = tools
            .map { "- \($0.name): \($0.description)" }
            .joined(separator: "\n")
    }

    return """
    You are an AI assistant integrated into FSNotes++, a markdown note-taking app for macOS.

    Current context:
    - Active note: \(title)
    - Folder: \(folder)
    - Note content: \(ctx.noteContent)
    - Project: \(project)
    - Available tags: \(tags)
    - Editor mode: \(ctx.editorMode.rawValue)
    - Storage format: \(storage)

    You have access to tools for interacting with notes. Use them when appropriate:
    \(toolLines)

    Guidelines:
    - Be concise and helpful
    - When suggesting edits, explain what you'll change before doing so
    - Use write_note for large rewrites, edit_note for small changes
    - Always confirm destructive actions (delete_note) with the user
    - Respect the user's existing writing style and formatting
    - In WYSIWYG mode, never suggest raw text or attributed string manipulation — always use the provided tools
    """
}

// MARK: - Anthropic (Claude) Provider

class AnthropicProvider: AIProvider {
    private let apiKey: String
    private let model: String
    private let endpoint: String

    init(apiKey: String, model: String = "claude-sonnet-4-5-20250514", endpoint: String = "https://api.anthropic.com") {
        self.apiKey = apiKey
        self.model = model
        self.endpoint = endpoint
    }

    func sendMessage(messages: [ChatMessage], context: AIPromptContext, onToken: @escaping (String) -> Void, onComplete: @escaping (Result<String, Error>) -> Void) {
        guard let url = URL(string: "\(endpoint)/v1/messages") else {
            onComplete(.failure(AIError.invalidURL))
            return
        }

        let systemPrompt = aiSystemPrompt(context)

        // Build messages array for Anthropic API
        var apiMessages: [[String: String]] = []
        for msg in messages where msg.role != .system {
            apiMessages.append(["role": msg.role.rawValue, "content": msg.content])
        }

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 4096,
            "stream": true,
            "system": systemPrompt,
            "messages": apiMessages
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else {
            onComplete(.failure(AIError.serializationFailed))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = jsonData

        let session = URLSession(configuration: .default, delegate: SSEDelegate(onToken: onToken, onComplete: onComplete, format: .anthropic), delegateQueue: nil)
        let task = session.dataTask(with: request)
        task.resume()
    }
}

// MARK: - OpenAI Provider

class OpenAIProvider: AIProvider {
    private let apiKey: String
    private let model: String
    private let endpoint: String

    init(apiKey: String, model: String = "gpt-4o", endpoint: String = "https://api.openai.com") {
        self.apiKey = apiKey
        self.model = model
        self.endpoint = endpoint
    }

    func sendMessage(messages: [ChatMessage], context: AIPromptContext, onToken: @escaping (String) -> Void, onComplete: @escaping (Result<String, Error>) -> Void) {
        guard let url = URL(string: "\(endpoint)/v1/chat/completions") else {
            onComplete(.failure(AIError.invalidURL))
            return
        }

        let systemMessage: [String: String] = [
            "role": "system",
            "content": aiSystemPrompt(context)
        ]

        var apiMessages: [[String: String]] = [systemMessage]
        for msg in messages where msg.role != .system {
            apiMessages.append(["role": msg.role.rawValue, "content": msg.content])
        }

        let body: [String: Any] = [
            "model": model,
            "stream": true,
            "messages": apiMessages
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else {
            onComplete(.failure(AIError.serializationFailed))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData

        let session = URLSession(configuration: .default, delegate: SSEDelegate(onToken: onToken, onComplete: onComplete, format: .openai), delegateQueue: nil)
        let task = session.dataTask(with: request)
        task.resume()
    }
}

// MARK: - SSE Stream Parser

enum SSEFormat {
    case anthropic
    case openai
}

class SSEDelegate: NSObject, URLSessionDataDelegate {
    private var onToken: (String) -> Void
    private var onComplete: (Result<String, Error>) -> Void
    private var format: SSEFormat
    private var buffer = ""
    private var fullResponse = ""
    private var hasCompleted = false

    init(onToken: @escaping (String) -> Void, onComplete: @escaping (Result<String, Error>) -> Void, format: SSEFormat) {
        self.onToken = onToken
        self.onComplete = onComplete
        self.format = format
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        buffer += text

        while let lineEnd = buffer.range(of: "\n") {
            let line = String(buffer[buffer.startIndex..<lineEnd.lowerBound])
            buffer = String(buffer[lineEnd.upperBound...])

            guard line.hasPrefix("data: ") else { continue }
            let jsonStr = String(line.dropFirst(6))

            if jsonStr == "[DONE]" {
                DispatchQueue.main.async {
                    guard !self.hasCompleted else { return }
                    self.hasCompleted = true
                    self.onComplete(.success(self.fullResponse))
                }
                return
            }

            guard let jsonData = jsonStr.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else { continue }

            var token: String?

            switch format {
            case .anthropic:
                if let type = json["type"] as? String {
                    if type == "content_block_delta",
                       let delta = json["delta"] as? [String: Any],
                       let text = delta["text"] as? String {
                        token = text
                    } else if type == "message_stop" {
                        DispatchQueue.main.async {
                            guard !self.hasCompleted else { return }
                            self.hasCompleted = true
                            self.onComplete(.success(self.fullResponse))
                        }
                        return
                    } else if type == "error",
                              let error = json["error"] as? [String: Any],
                              let message = error["message"] as? String {
                        DispatchQueue.main.async {
                            guard !self.hasCompleted else { return }
                            self.hasCompleted = true
                            self.onComplete(.failure(AIError.apiError(message)))
                        }
                        return
                    }
                }

            case .openai:
                if let choices = json["choices"] as? [[String: Any]],
                   let delta = choices.first?["delta"] as? [String: Any],
                   let content = delta["content"] as? String {
                    token = content
                }
            }

            if let token = token {
                fullResponse += token
                DispatchQueue.main.async {
                    self.onToken(token)
                }
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        session.finishTasksAndInvalidate()
        DispatchQueue.main.async {
            guard !self.hasCompleted else { return }
            self.hasCompleted = true
            if let error = error {
                self.onComplete(.failure(error))
            } else if !self.fullResponse.isEmpty {
                self.onComplete(.success(self.fullResponse))
            }
        }
    }
}

// MARK: - Errors

enum AIError: LocalizedError {
    case invalidURL
    case serializationFailed
    case noAPIKey
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid API URL"
        case .serializationFailed: return "Failed to serialize request"
        case .noAPIKey: return "No API key configured. Go to Preferences > AI to set one."
        case .apiError(let msg): return "API error: \(msg)"
        }
    }
}

// MARK: - Provider Factory

class AIServiceFactory {
    static func createProvider() -> AIProvider? {
        let provider = UserDefaultsManagement.aiProvider
        let model = UserDefaultsManagement.aiModel
        let endpoint = UserDefaultsManagement.aiEndpoint

        // Ollama is local and has no API key.
        if provider == "ollama" {
            let host = UserDefaultsManagement.aiOllamaHost
            return OllamaProvider(
                host: host.isEmpty ? "http://localhost:11434" : host,
                model: model.isEmpty ? "llama3.2" : model
            )
        }

        // The cloud providers below all require an API key.
        let apiKey = UserDefaultsManagement.aiAPIKey
        guard !apiKey.isEmpty else { return nil }

        switch provider {
        case "openai":
            return OpenAIProvider(
                apiKey: apiKey,
                model: model.isEmpty ? "gpt-4o" : model,
                endpoint: endpoint.isEmpty ? "https://api.openai.com" : endpoint
            )
        default: // "anthropic" or default
            return AnthropicProvider(
                apiKey: apiKey,
                model: model.isEmpty ? "claude-sonnet-4-5-20250514" : model,
                endpoint: endpoint.isEmpty ? "https://api.anthropic.com" : endpoint
            )
        }
    }
}
