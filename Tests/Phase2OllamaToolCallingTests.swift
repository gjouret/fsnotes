//
//  Phase2OllamaToolCallingTests.swift
//  FSNotesTests
//
//  Tests for the Ollama ↔ MCPServer tool-calling loop:
//    - Request body now includes the `tools` array from MCPServer.
//    - The NDJSON parser surfaces `OllamaStreamOutcome.toolCalls(...)`.
//    - `sendMessage` runs a continuation loop, dispatching each round of
//      tool calls via `MCPServer.handleToolCalls` and re-issuing chat
//      with the results appended.
//    - Iteration depth is capped at `OllamaProvider.maxToolRounds`.
//
//  All tests are hermetic — they inject a mock URLSession that serves
//  canned NDJSON responses through a custom URLProtocol subclass, so no
//  real Ollama server is required.
//

import XCTest
@testable import FSNotes

// MARK: - Mock URLProtocol

/// Per-instance store of (request → response bytes) so multiple test cases
/// running in parallel don't collide on global state. Each test installs
/// its responder closure for the URL it expects to hit.
private final class StubResponder {
    static let shared = StubResponder()
    private let lock = NSLock()
    /// Indexed by URL absolute string. Each call pops the *first* registered
    /// response, which lets tests script "round 1 returns a tool_call, round
    /// 2 returns text" by registering two responses for the same URL.
    private var queues: [String: [Data]] = [:]
    /// Captured request bodies, one per dataTask, in arrival order. Tests
    /// inspect this to assert the second round's conversation includes the
    /// tool result message.
    var capturedBodies: [Data] = []

    func enqueue(_ data: Data, for url: URL) {
        lock.lock(); defer { lock.unlock() }
        queues[url.absoluteString, default: []].append(data)
    }

    func dequeue(for url: URL) -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard var q = queues[url.absoluteString], !q.isEmpty else { return nil }
        let first = q.removeFirst()
        queues[url.absoluteString] = q
        return first
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        queues.removeAll()
        capturedBodies.removeAll()
    }
}

private final class OllamaStubURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { return true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { return request }

    override func startLoading() {
        // Capture body. URLProtocol substitutes `httpBodyStream` for `httpBody`
        // on POSTs, so try both shapes.
        if let body = request.httpBody {
            StubResponder.shared.capturedBodies.append(body)
        } else if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            let bufSize = 4096
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
            defer { buf.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buf, maxLength: bufSize)
                if read <= 0 { break }
                data.append(buf, count: read)
            }
            stream.close()
            StubResponder.shared.capturedBodies.append(data)
        }

        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: NSError(domain: "OllamaStubURLProtocol", code: 1))
            return
        }
        let payload = StubResponder.shared.dequeue(for: url) ?? Data()
        let response = HTTPURLResponse(url: url,
                                       statusCode: 200,
                                       httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/x-ndjson"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - Recording stub tool

/// Tool that records every invocation and returns a canned payload. Used
/// across the tool-call dispatch tests.
private final class RecordingTool: MCPTool {
    let name: String
    let description: String = "records every call"
    let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "x": ["type": "string"]
        ]
    ]
    final class Recorder {
        var calls: [[String: Any]] = []
    }
    let recorder: Recorder
    let response: [String: Any]

    init(name: String, response: [String: Any] = ["ok": true], recorder: Recorder = Recorder()) {
        self.name = name
        self.recorder = recorder
        self.response = response
    }

    func execute(input: [String: Any]) async -> ToolOutput {
        recorder.calls.append(input)
        return .success(response)
    }
}

// MARK: - Test fixtures

private func makeStubSessionFactory() -> (URLSessionDelegate) -> URLSession {
    return { delegate in
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OllamaStubURLProtocol.self] + (config.protocolClasses ?? [])
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }
}

private func enqueueTextResponse(_ text: String, url: URL) {
    let line1 = #"{"message":{"role":"assistant","content":"\#(text)"},"done":false}"# + "\n"
    let line2 = #"{"done":true}"# + "\n"
    StubResponder.shared.enqueue(Data((line1 + line2).utf8), for: url)
}

/// Build an NDJSON payload that streams a tool_call followed by `done:true`.
/// `argsJSON` is the *raw* JSON string for the function.arguments field; this
/// lets tests script malformed arguments too.
private func enqueueToolCallResponse(name: String,
                                     argsJSON: String,
                                     id: String? = nil,
                                     url: URL) {
    var entry = #"{"function":{"name":"\#(name)","arguments":\#(argsJSON)}}"#
    if let id = id {
        entry = #"{"id":"\#(id)","function":{"name":"\#(name)","arguments":\#(argsJSON)}}"#
    }
    let line1 = #"{"message":{"role":"assistant","content":"","tool_calls":[\#(entry)]},"done":false}"# + "\n"
    let line2 = #"{"done":true}"# + "\n"
    StubResponder.shared.enqueue(Data((line1 + line2).utf8), for: url)
}

private let stubURL: URL = {
    return URL(string: "http://localhost:11434/api/chat")!
}()

// MARK: - Tests

final class Phase2OllamaToolCallingTests: XCTestCase {

    override func setUp() {
        super.setUp()
        StubResponder.shared.reset()
    }

    // MARK: Slice 1 — request body carries tools

    func testRequestBody_includesToolSchemasFromMCPServer() throws {
        let server = MCPServer(storageRoot: nil, appBridge: NoOpAppBridge())
        server.registerTool(RecordingTool(name: "alpha"))
        server.registerTool(RecordingTool(name: "beta"))

        let provider = OllamaProvider(host: "http://localhost:11434",
                                      model: "llama3.2",
                                      mcpServer: server)
        let request = try provider.makeChatRequest(
            messages: [ChatMessage(role: .user, content: "hi")],
            noteContent: ""
        )
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let tools = try XCTUnwrap(json["tools"] as? [[String: Any]])

        XCTAssertEqual(tools.count, 2)
        let names = tools.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }.sorted()
        XCTAssertEqual(names, ["alpha", "beta"])
        for entry in tools {
            XCTAssertEqual(entry["type"] as? String, "function")
            let fn = try XCTUnwrap(entry["function"] as? [String: Any])
            XCTAssertNotNil(fn["description"])
            XCTAssertNotNil(fn["parameters"])
        }
    }

    // MARK: Slice 2 — parser surfaces tool_calls

    func testParser_singleToolCallProducesToolCallsOutcome() {
        let exp = expectation(description: "complete")
        var outcome: OllamaStreamOutcome?
        let parser = OllamaStreamParser(
            onToken: { _ in },
            onComplete: { (result: Result<OllamaStreamOutcome, Error>) in
                if case .success(let oc) = result { outcome = oc }
                exp.fulfill()
            }
        )
        let line1 = #"{"message":{"role":"assistant","content":"","tool_calls":[{"function":{"name":"read_note","arguments":{"title":"Inbox"}}}]},"done":false}"# + "\n"
        let line2 = #"{"done":true}"# + "\n"
        parser.feed(line1)
        parser.feed(line2)

        wait(for: [exp], timeout: 5.0)
        guard case .toolCalls(let calls, let preamble) = outcome else {
            XCTFail("expected .toolCalls outcome, got \(String(describing: outcome))")
            return
        }
        XCTAssertEqual(preamble, "")
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "read_note")
        XCTAssertEqual(calls[0].arguments["title"] as? String, "Inbox")
        XCTAssertFalse(calls[0].id.isEmpty, "id should be synthesised when omitted")
    }

    func testParser_multipleToolCallsInOneLine() {
        let exp = expectation(description: "complete")
        var outcome: OllamaStreamOutcome?
        let parser = OllamaStreamParser(
            onToken: { _ in },
            onComplete: { (result: Result<OllamaStreamOutcome, Error>) in
                if case .success(let oc) = result { outcome = oc }
                exp.fulfill()
            }
        )
        let line1 = #"{"message":{"role":"assistant","content":"","tool_calls":[{"function":{"name":"a","arguments":{}}},{"function":{"name":"b","arguments":{}}}]},"done":false}"# + "\n"
        let line2 = #"{"done":true}"# + "\n"
        parser.feed(line1)
        parser.feed(line2)

        wait(for: [exp], timeout: 5.0)
        guard case .toolCalls(let calls, _) = outcome else {
            XCTFail("expected .toolCalls outcome")
            return
        }
        XCTAssertEqual(calls.map { $0.name }, ["a", "b"])
    }

    func testParser_argumentsMayBeJSONString() {
        // Some model frontends serialise arguments as a JSON string.
        let exp = expectation(description: "complete")
        var outcome: OllamaStreamOutcome?
        let parser = OllamaStreamParser(
            onToken: { _ in },
            onComplete: { (result: Result<OllamaStreamOutcome, Error>) in
                if case .success(let oc) = result { outcome = oc }
                exp.fulfill()
            }
        )
        let line1 = #"{"message":{"role":"assistant","tool_calls":[{"function":{"name":"x","arguments":"{\"k\":\"v\"}"}}]},"done":false}"# + "\n"
        parser.feed(line1)
        parser.feed(#"{"done":true}"# + "\n")

        wait(for: [exp], timeout: 5.0)
        guard case .toolCalls(let calls, _) = outcome else {
            XCTFail("expected .toolCalls outcome")
            return
        }
        XCTAssertEqual(calls[0].arguments["k"] as? String, "v")
    }

    func testParser_textOnlyStreamProducesTextOutcome() {
        let exp = expectation(description: "complete")
        var outcome: OllamaStreamOutcome?
        let parser = OllamaStreamParser(
            onToken: { _ in },
            onComplete: { (result: Result<OllamaStreamOutcome, Error>) in
                if case .success(let oc) = result { outcome = oc }
                exp.fulfill()
            }
        )
        parser.feed(#"{"message":{"role":"assistant","content":"hi"},"done":false}"# + "\n")
        parser.feed(#"{"done":true}"# + "\n")

        wait(for: [exp], timeout: 5.0)
        guard case .text(let s) = outcome else {
            XCTFail("expected .text outcome")
            return
        }
        XCTAssertEqual(s, "hi")
    }

    // MARK: Slice 3 — full sendMessage continuation loop

    func testSendMessage_textOnlyStreamCompletesOnce() {
        enqueueTextResponse("hello there", url: stubURL)

        let server = MCPServer(storageRoot: nil, appBridge: NoOpAppBridge())
        let provider = OllamaProvider(host: "http://localhost:11434",
                                      model: "llama3.2",
                                      mcpServer: server,
                                      sessionFactory: makeStubSessionFactory())

        let exp = expectation(description: "complete")
        var completionCount = 0
        var captured: String?
        var tokens: [String] = []

        provider.sendMessage(
            messages: [ChatMessage(role: .user, content: "hi")],
            noteContent: "",
            onToken: { tokens.append($0) },
            onComplete: { result in
                completionCount += 1
                if case .success(let s) = result { captured = s }
                exp.fulfill()
            }
        )
        wait(for: [exp], timeout: 5.0)
        XCTAssertEqual(completionCount, 1)
        XCTAssertEqual(captured, "hello there")
        XCTAssertEqual(tokens, ["hello there"])
    }

    func testSendMessage_singleToolCallDispatchesAndContinues() {
        // Round 1: model emits a tool_call. Round 2: model emits text.
        enqueueToolCallResponse(name: "alpha",
                                argsJSON: #"{"x":"hello"}"#,
                                id: "call_1",
                                url: stubURL)
        enqueueTextResponse("done", url: stubURL)

        let recorder = RecordingTool.Recorder()
        let server = MCPServer(storageRoot: nil, appBridge: NoOpAppBridge())
        server.registerTool(RecordingTool(name: "alpha", recorder: recorder))

        let provider = OllamaProvider(host: "http://localhost:11434",
                                      model: "llama3.2",
                                      mcpServer: server,
                                      sessionFactory: makeStubSessionFactory())

        let exp = expectation(description: "complete")
        var captured: String?
        provider.sendMessage(
            messages: [ChatMessage(role: .user, content: "do the thing")],
            noteContent: "",
            onToken: { _ in },
            onComplete: { result in
                if case .success(let s) = result { captured = s }
                exp.fulfill()
            }
        )
        wait(for: [exp], timeout: 5.0)

        XCTAssertEqual(captured, "done")
        XCTAssertEqual(recorder.calls.count, 1, "tool dispatched exactly once")
        XCTAssertEqual(recorder.calls[0]["x"] as? String, "hello")

        // Verify the second request body included the tool result.
        XCTAssertEqual(StubResponder.shared.capturedBodies.count, 2,
                       "expected two round-trips: original + post-tool")
        let secondBody = StubResponder.shared.capturedBodies[1]
        let json = try? JSONSerialization.jsonObject(with: secondBody) as? [String: Any]
        let messages = (json?["messages"] as? [[String: Any]]) ?? []
        let toolMessages = messages.filter { ($0["role"] as? String) == "tool" }
        XCTAssertEqual(toolMessages.count, 1)
        XCTAssertEqual(toolMessages.first?["name"] as? String, "alpha")
        XCTAssertEqual(toolMessages.first?["tool_call_id"] as? String, "call_1")
        let assistantToolCallMessages = messages.filter {
            ($0["role"] as? String) == "assistant" && $0["tool_calls"] != nil
        }
        XCTAssertEqual(assistantToolCallMessages.count, 1,
                       "assistant tool_call message must be echoed back")
    }

    func testSendMessage_multipleToolCallsInOneRoundDispatchAllInBatch() {
        // One streamed line carries two tool_calls.
        let entry1 = #"{"id":"c1","function":{"name":"alpha","arguments":{}}}"#
        let entry2 = #"{"id":"c2","function":{"name":"beta","arguments":{}}}"#
        let line1 = #"{"message":{"role":"assistant","content":"","tool_calls":[\#(entry1),\#(entry2)]},"done":false}"# + "\n"
        let line2 = #"{"done":true}"# + "\n"
        StubResponder.shared.enqueue(Data((line1 + line2).utf8), for: stubURL)
        enqueueTextResponse("ok", url: stubURL)

        let aRecorder = RecordingTool.Recorder()
        let bRecorder = RecordingTool.Recorder()
        let server = MCPServer(storageRoot: nil, appBridge: NoOpAppBridge())
        server.registerTool(RecordingTool(name: "alpha", recorder: aRecorder))
        server.registerTool(RecordingTool(name: "beta", recorder: bRecorder))

        let provider = OllamaProvider(host: "http://localhost:11434",
                                      model: "llama3.2",
                                      mcpServer: server,
                                      sessionFactory: makeStubSessionFactory())

        let exp = expectation(description: "complete")
        provider.sendMessage(
            messages: [ChatMessage(role: .user, content: "go")],
            noteContent: "",
            onToken: { _ in },
            onComplete: { _ in exp.fulfill() }
        )
        wait(for: [exp], timeout: 5.0)

        XCTAssertEqual(aRecorder.calls.count, 1)
        XCTAssertEqual(bRecorder.calls.count, 1)
        XCTAssertEqual(StubResponder.shared.capturedBodies.count, 2,
                       "all calls dispatched in one batch — one continuation request")
    }

    func testSendMessage_iterationDepthCapEmitsError() {
        // Always return a tool_call. Loop must terminate at maxToolRounds.
        for _ in 0..<(OllamaProvider.maxToolRounds + 2) {
            enqueueToolCallResponse(name: "alpha",
                                    argsJSON: "{}",
                                    id: "loop",
                                    url: stubURL)
        }

        let server = MCPServer(storageRoot: nil, appBridge: NoOpAppBridge())
        server.registerTool(RecordingTool(name: "alpha"))

        let provider = OllamaProvider(host: "http://localhost:11434",
                                      model: "llama3.2",
                                      mcpServer: server,
                                      sessionFactory: makeStubSessionFactory())

        let exp = expectation(description: "complete")
        var captured: Error?
        provider.sendMessage(
            messages: [ChatMessage(role: .user, content: "loop")],
            noteContent: "",
            onToken: { _ in },
            onComplete: { result in
                if case .failure(let err) = result { captured = err }
                exp.fulfill()
            }
        )
        wait(for: [exp], timeout: 10.0)

        let err = try? XCTUnwrap(captured)
        XCTAssertNotNil(err)
        let desc = (err as? LocalizedError)?.errorDescription ?? "\(err.debugDescription)"
        XCTAssertTrue(desc.contains("\(OllamaProvider.maxToolRounds)"),
                      "expected error to mention the cap value, got: \(desc)")
        XCTAssertLessThanOrEqual(StubResponder.shared.capturedBodies.count,
                                 OllamaProvider.maxToolRounds,
                                 "loop must stop at the cap, not run forever")
    }

    func testSendMessage_unknownToolStillContinues() {
        // Model calls a tool that isn't registered. MCPServer returns
        // .error("Unknown tool: ..."), the provider feeds it back, and the
        // model produces a final text response.
        enqueueToolCallResponse(name: "ghost",
                                argsJSON: "{}",
                                id: "g1",
                                url: stubURL)
        enqueueTextResponse("recovered", url: stubURL)

        let server = MCPServer(storageRoot: nil, appBridge: NoOpAppBridge())
        let provider = OllamaProvider(host: "http://localhost:11434",
                                      model: "llama3.2",
                                      mcpServer: server,
                                      sessionFactory: makeStubSessionFactory())

        let exp = expectation(description: "complete")
        var captured: String?
        provider.sendMessage(
            messages: [ChatMessage(role: .user, content: "go")],
            noteContent: "",
            onToken: { _ in },
            onComplete: { result in
                if case .success(let s) = result { captured = s }
                exp.fulfill()
            }
        )
        wait(for: [exp], timeout: 5.0)
        XCTAssertEqual(captured, "recovered")

        // The continuation request must still carry a role:"tool" entry —
        // even error outcomes feed back to the model.
        XCTAssertEqual(StubResponder.shared.capturedBodies.count, 2)
        let secondBody = StubResponder.shared.capturedBodies[1]
        let json = try? JSONSerialization.jsonObject(with: secondBody) as? [String: Any]
        let messages = (json?["messages"] as? [[String: Any]]) ?? []
        let toolMessages = messages.filter { ($0["role"] as? String) == "tool" }
        XCTAssertEqual(toolMessages.count, 1)
        let content = toolMessages.first?["content"] as? String ?? ""
        XCTAssertTrue(content.contains("Unknown tool"),
                      "expected error envelope, got: \(content)")
    }

    func testSendMessage_malformedToolCallArgsStillDispatches() {
        // The parser tolerates `arguments` missing/unexpected types by
        // substituting an empty dict. The tool runs with `[:]`, returns
        // its canned payload, and the loop continues.
        let entry = #"{"function":{"name":"alpha","arguments":42}}"#  // not an object or string
        let line1 = #"{"message":{"role":"assistant","content":"","tool_calls":[\#(entry)]},"done":false}"# + "\n"
        let line2 = #"{"done":true}"# + "\n"
        StubResponder.shared.enqueue(Data((line1 + line2).utf8), for: stubURL)
        enqueueTextResponse("ok", url: stubURL)

        let recorder = RecordingTool.Recorder()
        let server = MCPServer(storageRoot: nil, appBridge: NoOpAppBridge())
        server.registerTool(RecordingTool(name: "alpha", recorder: recorder))

        let provider = OllamaProvider(host: "http://localhost:11434",
                                      model: "llama3.2",
                                      mcpServer: server,
                                      sessionFactory: makeStubSessionFactory())

        let exp = expectation(description: "complete")
        var captured: String?
        provider.sendMessage(
            messages: [ChatMessage(role: .user, content: "go")],
            noteContent: "",
            onToken: { _ in },
            onComplete: { result in
                if case .success(let s) = result { captured = s }
                exp.fulfill()
            }
        )
        wait(for: [exp], timeout: 5.0)

        XCTAssertEqual(captured, "ok")
        XCTAssertEqual(recorder.calls.count, 1)
        XCTAssertEqual(recorder.calls[0].count, 0, "args should fall through to empty dict")
    }
}
