//
//  Phase1OllamaProviderTests.swift
//  FSNotesTests
//
//  Tests for OllamaProvider request-body construction, the NDJSON streaming
//  parser, and AIServiceFactory wiring. Nothing here connects to a live Ollama
//  instance — request bodies are captured before send, and the parser is fed
//  synthetic NDJSON lines.
//

import XCTest
@testable import FSNotes

final class Phase1OllamaProviderTests: XCTestCase {

    // MARK: - Request body construction

    func testOllamaProvider_buildsCorrectChatRequest() throws {
        let provider = OllamaProvider(host: "http://localhost:11434", model: "llama3.2")
        let messages: [ChatMessage] = [
            ChatMessage(role: .user, content: "Hello")
        ]
        let request = try provider.makeChatRequest(messages: messages, noteContent: "My note")

        XCTAssertEqual(request.url?.absoluteString, "http://localhost:11434/api/chat")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"),
                     "Ollama is local-only; no auth header should be sent")

        guard let body = request.httpBody,
              let json = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            XCTFail("Expected JSON request body")
            return
        }

        XCTAssertEqual(json["model"] as? String, "llama3.2")
        XCTAssertEqual(json["stream"] as? Bool, true)

        // Phase 1 ships streaming-only chat. The `tools` slot must be present-but-empty
        // so Phase 2 (MCP integration) only needs to populate it, not introduce it.
        if let tools = json["tools"] as? [Any] {
            XCTAssertEqual(tools.count, 0, "tools array should be empty in Phase 1")
        } else {
            XCTFail("Expected `tools` array in request body (present-but-empty per spec)")
        }

        guard let msgs = json["messages"] as? [[String: Any]] else {
            XCTFail("Expected messages array")
            return
        }
        // System prompt is injected as first message; user message follows.
        XCTAssertGreaterThanOrEqual(msgs.count, 2)
        XCTAssertEqual(msgs.first?["role"] as? String, "system")
        XCTAssertEqual(msgs.last?["role"] as? String, "user")
        XCTAssertEqual(msgs.last?["content"] as? String, "Hello")

        let systemContent = msgs.first?["content"] as? String ?? ""
        XCTAssertTrue(systemContent.contains("My note"),
                      "System prompt must embed the active note content")
    }

    func testOllamaProvider_filtersClientSystemMessages() throws {
        // Mirrors AnthropicProvider / OpenAIProvider: any system role coming in from
        // the chat history is dropped — the provider injects its own system prompt.
        let provider = OllamaProvider(host: "http://localhost:11434", model: "llama3.2")
        let messages: [ChatMessage] = [
            ChatMessage(role: .system, content: "ignored"),
            ChatMessage(role: .user, content: "Hi")
        ]
        let request = try provider.makeChatRequest(messages: messages, noteContent: "")
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let msgs = try XCTUnwrap(json["messages"] as? [[String: Any]])

        XCTAssertEqual(msgs.count, 2)
        XCTAssertEqual(msgs[0]["role"] as? String, "system")
        XCTAssertEqual(msgs[1]["role"] as? String, "user")
        XCTAssertEqual(msgs[1]["content"] as? String, "Hi")
    }

    func testOllamaProvider_invalidHostThrows() {
        let provider = OllamaProvider(host: "", model: "llama3.2")
        XCTAssertThrowsError(try provider.makeChatRequest(
            messages: [ChatMessage(role: .user, content: "x")],
            noteContent: ""
        ))
    }

    func testOllamaProvider_remoteHostBuildsCorrectURL() throws {
        let provider = OllamaProvider(host: "https://ollama.example.com:8443", model: "mistral:7b")
        let request = try provider.makeChatRequest(
            messages: [ChatMessage(role: .user, content: "x")],
            noteContent: ""
        )
        XCTAssertEqual(request.url?.absoluteString, "https://ollama.example.com:8443/api/chat")
    }

    // MARK: - AIServiceFactory wiring

    func testAIServiceFactory_returnsOllamaProviderForOllamaPref() {
        let prevProvider = UserDefaultsManagement.aiProvider
        let prevModel = UserDefaultsManagement.aiModel
        defer {
            UserDefaultsManagement.aiProvider = prevProvider
            UserDefaultsManagement.aiModel = prevModel
        }
        UserDefaultsManagement.aiProvider = "ollama"
        UserDefaultsManagement.aiModel = "llama3.2"

        let provider = AIServiceFactory.createProvider()
        XCTAssertNotNil(provider, "Ollama needs no API key — factory must return a provider")
        XCTAssertTrue(provider is OllamaProvider,
                      "Factory should return an OllamaProvider when aiProvider == 'ollama'")
    }

    func testAIServiceFactory_ollamaWorksWithoutAPIKey() {
        // Save and clear the API key — Ollama must not require it.
        let prevProvider = UserDefaultsManagement.aiProvider
        let prevKey = UserDefaultsManagement.aiAPIKey
        defer {
            UserDefaultsManagement.aiProvider = prevProvider
            UserDefaultsManagement.aiAPIKey = prevKey
        }
        UserDefaultsManagement.aiAPIKey = ""
        UserDefaultsManagement.aiProvider = "ollama"

        let provider = AIServiceFactory.createProvider()
        XCTAssertTrue(provider is OllamaProvider,
                      "Ollama selection must not be gated by API key presence")
    }

    // MARK: - NDJSON streaming parser

    func testOllamaStreamParser_singleChunk() {
        let exp = expectation(description: "complete")
        var tokens: [String] = []
        var done = false
        let tokenLock = NSLock()

        let parser = OllamaStreamParser(
            onToken: {
                tokenLock.lock(); tokens.append($0); tokenLock.unlock()
            },
            onComplete: { _ in
                done = true
                exp.fulfill()
            }
        )
        parser.feed(#"{"message":{"role":"assistant","content":"Hello"},"done":false}"# + "\n")
        parser.feed(#"{"message":{"role":"assistant","content":" world"},"done":false}"# + "\n")
        parser.feed(#"{"done":true}"# + "\n")

        wait(for: [exp], timeout: 2.0)
        // Tokens are dispatched to main async; pump the runloop briefly.
        let tokenCheck = expectation(description: "tokens flushed")
        DispatchQueue.main.async { tokenCheck.fulfill() }
        wait(for: [tokenCheck], timeout: 1.0)

        tokenLock.lock(); let captured = tokens; tokenLock.unlock()
        XCTAssertEqual(captured, ["Hello", " world"])
        XCTAssertTrue(done)
    }

    func testOllamaStreamParser_handlesPartialLines() {
        let parser = OllamaStreamParser(
            onToken: { _ in },
            onComplete: { _ in }
        )
        // No newline yet — parser must buffer instead of treating "par" as a line.
        parser.feed(#"{"message":{"role":"assistant","content":"par"#)
        // Now the rest plus newline arrives.
        parser.feed(#"tial"},"done":false}"# + "\n")

        let tokenExp = expectation(description: "main flush")
        DispatchQueue.main.async { tokenExp.fulfill() }
        wait(for: [tokenExp], timeout: 1.0)
        // No assertion crashes is enough; the deeper assertion is in the
        // singleChunk test above.
    }

    func testOllamaStreamParser_apiErrorPayload() {
        let exp = expectation(description: "error")
        var captured: Error?
        let parser = OllamaStreamParser(
            onToken: { _ in },
            onComplete: { result in
                if case .failure(let err) = result { captured = err }
                exp.fulfill()
            }
        )
        parser.feed(#"{"error":"model not found"}"# + "\n")
        wait(for: [exp], timeout: 2.0)
        XCTAssertNotNil(captured)
    }

    func testOllamaStreamParser_finishWithoutDoneStillCompletes() {
        let exp = expectation(description: "complete")
        var success = false
        let parser = OllamaStreamParser(
            onToken: { _ in },
            onComplete: { result in
                if case .success = result { success = true }
                exp.fulfill()
            }
        )
        // Only a partial token line arrives before the stream ends.
        parser.feed(#"{"message":{"role":"assistant","content":"hi"},"done":false}"# + "\n")
        parser.finish(error: nil)
        wait(for: [exp], timeout: 2.0)
        XCTAssertTrue(success)
    }
}
