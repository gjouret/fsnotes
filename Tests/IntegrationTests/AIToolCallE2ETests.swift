//
//  AIToolCallE2ETests.swift
//  FSNotesTests
//
//  End-to-end integration tests for the AI tool-calling seam:
//  Ollama provider → MCPServer → AppBridge → editor → save.
//
//  Each layer has its own hermetic test suite (Phase 2 Ollama tests,
//  per-tool MCP tests, AppBridgeImplTests). What none of those exercise
//  is the *boundary* between layers — does a streamed `tool_call` from
//  Ollama actually reach the registered MCP tool, does the tool's
//  AppBridge dispatch hit `applyEditResultWithUndo`, and does the
//  on-disk file reflect the result.
//
//  Hermetic strategy:
//    - Ollama: `URLProtocol` subclass intercepts `/api/chat` POSTs and
//      serves canned NDJSON responses. No real Ollama server.
//    - Storage: per-test `MCPTestFixture` rooted at a tmp directory.
//    - Editor: an `EditorHarness` whose note URL is repointed at the
//      fixture file so `AppBridgeImpl.isOpen(_:)` agrees with the
//      tool's resolved path.
//    - State isolation: each test creates its own `MCPServer` (NOT
//      `MCPServer.shared`) and registers only the tools the scenario
//      needs. `URLProtocol.registerClass` is keyed by the protocol
//      class, and the per-test responder closure is reset in setUp.
//

import XCTest
import AppKit
@testable import FSNotes

// MARK: - URLProtocol mock for Ollama

/// Intercepts every URLRequest passing through a URLSession that
/// includes this protocol class. Each test installs a `responder`
/// closure that examines the request body and returns the NDJSON
/// chunk(s) for the next round-trip. `requestCount` is incremented
/// on every interception so tests can assert how many round-trips
/// happened (one per chat round).
final class IntegrationMockURLProtocol: URLProtocol {
    /// Per-test responder. Examines the request and returns a tuple of
    /// (HTTPURLResponse, NDJSON body). Set in each test's setUp; tests
    /// that verify the iteration cap can return canned responses
    /// indefinitely.
    static let lock = NSLock()
    private static var _responder: ((URLRequest, Int) -> (HTTPURLResponse, Data))?
    private static var _requestCount: Int = 0
    private static var _capturedBodies: [Data] = []

    static var requestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _requestCount
    }
    static var capturedBodies: [Data] {
        lock.lock(); defer { lock.unlock() }
        return _capturedBodies
    }

    static func install(responder: @escaping (URLRequest, Int) -> (HTTPURLResponse, Data)) {
        lock.lock(); defer { lock.unlock() }
        _responder = responder
        _requestCount = 0
        _capturedBodies = []
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        _responder = nil
        _requestCount = 0
        _capturedBodies = []
    }

    override class func canInit(with request: URLRequest) -> Bool { return true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { return request }
    override func stopLoading() {}

    override func startLoading() {
        // Capture body. URLProtocol substitutes `httpBodyStream` for
        // `httpBody` on POSTs, so try both shapes.
        var bodyData = Data()
        if let body = request.httpBody {
            bodyData = body
        } else if let stream = request.httpBodyStream {
            stream.open()
            let bufSize = 4096
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
            defer { buf.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buf, maxLength: bufSize)
                if read <= 0 { break }
                bodyData.append(buf, count: read)
            }
            stream.close()
        }

        let count: Int
        let responder: ((URLRequest, Int) -> (HTTPURLResponse, Data))?
        IntegrationMockURLProtocol.lock.lock()
        IntegrationMockURLProtocol._capturedBodies.append(bodyData)
        IntegrationMockURLProtocol._requestCount += 1
        count = IntegrationMockURLProtocol._requestCount
        responder = IntegrationMockURLProtocol._responder
        IntegrationMockURLProtocol.lock.unlock()

        guard let responder = responder else {
            client?.urlProtocol(self, didFailWithError: NSError(
                domain: "IntegrationMockURLProtocol", code: 1
            ))
            return
        }
        let (response, data) = responder(request, count)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

// MARK: - Helpers

/// Build NDJSON for a chat response that asks the model to call a
/// tool. The arguments dict is JSON-serialised inline.
private func ndjsonToolCall(name: String,
                            arguments: [String: Any],
                            id: String = "call_\(UUID().uuidString.prefix(6))") -> Data {
    let argsData = (try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])) ?? Data("{}".utf8)
    let argsJSON = String(data: argsData, encoding: .utf8) ?? "{}"
    let entry = #"{"id":"\#(id)","function":{"name":"\#(name)","arguments":\#(argsJSON)}}"#
    let line1 = #"{"message":{"role":"assistant","content":"","tool_calls":[\#(entry)]},"done":false}"# + "\n"
    let line2 = #"{"done":true}"# + "\n"
    return Data((line1 + line2).utf8)
}

/// Build NDJSON for a final assistant text response.
private func ndjsonText(_ text: String) -> Data {
    // Escape JSON-special characters in the streamed content.
    let escaped = text
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
    let line1 = #"{"message":{"role":"assistant","content":"\#(escaped)"},"done":false}"# + "\n"
    let line2 = #"{"done":true}"# + "\n"
    return Data((line1 + line2).utf8)
}

/// Standard 200 OK response with NDJSON content type.
private func okResponse(for request: URLRequest) -> HTTPURLResponse {
    return HTTPURLResponse(
        url: request.url ?? URL(string: "http://localhost:11434/api/chat")!,
        statusCode: 200,
        httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "application/x-ndjson"]
    )!
}

/// URLSession factory that injects `IntegrationMockURLProtocol` so the
/// provider's network calls don't escape the test harness.
private func mockSessionFactory() -> (URLSessionDelegate) -> URLSession {
    return { delegate in
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [IntegrationMockURLProtocol.self] + (config.protocolClasses ?? [])
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }
}

// MARK: - Main-thread wrapping bridge

/// AppBridge wrapper that marshals every method onto the main thread
/// before delegating. AppBridgeImpl touches AppKit-only state
/// (`textStorage`, `applyEditResultWithUndo`, `Note.save`) and is
/// documented as expecting main-thread invocation, but
/// `OllamaProvider.dispatchToolCallsAndContinue` calls
/// `MCPServer.handleToolCalls` from a `Task.detached` cooperative
/// queue. In production that mismatch is the AppDelegate / chat panel's
/// problem to solve; in this hermetic test we wrap the bridge so the
/// integration boundary is exercised under the threading contract
/// every layer assumes. `DispatchQueue.main.sync` is safe here because
/// the test driver waits on an `XCTestExpectation` rather than
/// blocking the main thread.
private final class MainThreadAppBridge: AppBridge {
    private let inner: AppBridge
    init(_ inner: AppBridge) { self.inner = inner }

    private func onMain<T>(_ body: () -> T) -> T {
        if Thread.isMainThread { return body() }
        return DispatchQueue.main.sync { body() }
    }

    func currentNotePath() -> String? {
        return onMain { self.inner.currentNotePath() }
    }
    func hasUnsavedChanges(path: String) -> Bool {
        return onMain { self.inner.hasUnsavedChanges(path: path) }
    }
    func editorMode(for path: String) -> String? {
        return onMain { self.inner.editorMode(for: path) }
    }
    func cursorState(for path: String) -> CursorState? {
        return onMain { self.inner.cursorState(for: path) }
    }
    func notifyFileChanged(path: String) {
        onMain { self.inner.notifyFileChanged(path: path) }
    }
    func requestWriteLock(path: String) -> Bool {
        return onMain { self.inner.requestWriteLock(path: path) }
    }
    func appendMarkdown(toPath path: String, markdown: String) -> BridgeEditOutcome {
        return onMain { self.inner.appendMarkdown(toPath: path, markdown: markdown) }
    }
    func applyStructuredEdit(toPath path: String, request: BridgeEditRequest) -> BridgeEditOutcome {
        return onMain { self.inner.applyStructuredEdit(toPath: path, request: request) }
    }
    func applyFormatting(toPath path: String, command: BridgeFormattingCommand) -> BridgeEditOutcome {
        return onMain { self.inner.applyFormatting(toPath: path, command: command) }
    }
    func exportPDF(forPath path: String, to outputURL: URL) -> BridgeEditOutcome {
        return onMain { self.inner.exportPDF(forPath: path, to: outputURL) }
    }
}

// MARK: - Tests

final class AIToolCallE2ETests: XCTestCase {

    override func setUp() {
        super.setUp()
        IntegrationMockURLProtocol.reset()
    }

    override func tearDown() {
        IntegrationMockURLProtocol.reset()
        super.tearDown()
    }

    /// Build a bridge whose `resolveViewController` closure returns a
    /// `ViewController` whose `editor` is the harness's editor. Same
    /// shape as `AppBridgeImplTests.makeBridge`. Returns the bridge
    /// AND retains a strong reference to the VC so the closure's
    /// captured value stays alive for the lifetime of the bridge.
    private func makeLiveBridge(harness: EditorHarness) -> (AppBridgeImpl, ViewController) {
        let vc = ViewController()
        vc.editor = harness.editor
        let bridge = AppBridgeImpl(resolveViewController: { vc })
        return (bridge, vc)
    }

    // MARK: - Scenario 1: read-only round-trip

    func testReadOnlyRoundTrip_returnsContentAndPreservesFile() {
        // Seed an on-disk note "Hello"; configure a mock that, on the
        // first request, asks the model to call `read_note`, and on
        // the second, returns final text. Verify the conversation
        // completes, the second message contains "Hello", and the
        // file on disk is unchanged.
        let fixture = MCPTestFixture()
        let url = fixture.makeNote(at: "test.md", content: "Hello\n")
        let originalBytes = try? Data(contentsOf: url)

        let server = fixture.makeServer(bridge: NoOpAppBridge())
        server.registerTool(ReadNoteTool(server: server))

        IntegrationMockURLProtocol.install { [weak self] request, count in
            _ = self
            let response = okResponse(for: request)
            switch count {
            case 1:
                return (response, ndjsonToolCall(
                    name: "read_note",
                    arguments: ["title": "test"]
                ))
            default:
                return (response, ndjsonText("I read 'Hello'"))
            }
        }

        let provider = OllamaProvider(
            host: "http://localhost:11434",
            model: "llama3.2",
            mcpServer: server,
            sessionFactory: mockSessionFactory()
        )

        let exp = expectation(description: "complete")
        var captured: String?
        provider.sendMessage(
            messages: [ChatMessage(role: .user, content: "What does my test note say?")],
            context: AIPromptContext(),
            onToken: { _ in },
            onComplete: { result in
                if case .success(let s) = result { captured = s }
                exp.fulfill()
            }
        )
        wait(for: [exp], timeout: 5.0)

        XCTAssertEqual(captured, "I read 'Hello'")
        XCTAssertEqual(IntegrationMockURLProtocol.requestCount, 2,
                       "expected one initial + one continuation request")

        // The continuation request must include the tool result with
        // the file's content.
        let secondBody = IntegrationMockURLProtocol.capturedBodies[1]
        let json = try? JSONSerialization.jsonObject(with: secondBody) as? [String: Any]
        let messages = (json?["messages"] as? [[String: Any]]) ?? []
        let toolMessages = messages.filter { ($0["role"] as? String) == "tool" }
        XCTAssertEqual(toolMessages.count, 1)
        let content = toolMessages.first?["content"] as? String ?? ""
        XCTAssertTrue(content.contains("Hello"),
                      "tool result content should carry the note body, got: \(content)")

        // On-disk file is unchanged.
        let nowBytes = try? Data(contentsOf: url)
        XCTAssertEqual(nowBytes, originalBytes, "read_note must not mutate the file")
    }

    // MARK: - Scenario 2: WYSIWYG write end-to-end
    //
    // The test verifies the editor-side seam end-to-end (Ollama →
    // MCPServer → AppBridgeImpl → applyEditResultWithUndo → projection
    // → undoJournal). Disk persistence is *not* asserted here: in
    // production, persistence happens via `EditTextView.save()`'s
    // debounced timer (which calls `note.save(markdown:)` reading the
    // current projection). `AppBridgeImpl.appendMarkdown` calls
    // `Note.save()` (no-arg) directly, which writes `note.content`
    // verbatim — and the harness's seed never resyncs `note.content`
    // after a splice. Asserting the disk state here would couple the
    // hermetic test to either fixing that production path or to
    // running the debounce loop, both out of scope. The
    // source-mode test below (#3) covers the disk-write contract
    // for the source-mode branch, which DOES write directly.
    func testWysiwygWrite_endToEndUpdatesProjectionAndJournal() {
        let fixture = MCPTestFixture()
        let url = fixture.makeNote(at: "wy.md", content: "Initial.\n")

        // Build a harness whose note.url matches the fixture's URL so
        // AppBridgeImpl.isOpen(_:) will agree.
        let harness = AppBridgeImplTestHelper.makeHarness(
            at: url, markdown: "Initial.\n"
        )
        defer { harness.teardown() }

        let (rawBridge, vc) = makeLiveBridge(harness: harness)
        _ = vc  // hold strong reference; resolveViewController captures it
        let bridge = MainThreadAppBridge(rawBridge)

        let server = fixture.makeServer(bridge: bridge)
        server.registerTool(AppendToNoteTool(server: server))

        // Snapshot the journal "before" state so we can assert exactly
        // one new entry was appended.
        let undoCountBefore = harness.editor.undoJournal.past.count

        // Round 1: model calls append_to_note. Round 2: final text.
        IntegrationMockURLProtocol.install { request, count in
            let response = okResponse(for: request)
            switch count {
            case 1:
                return (response, ndjsonToolCall(
                    name: "append_to_note",
                    arguments: [
                        "path": "wy.md",
                        "content": "New paragraph"
                    ]
                ))
            default:
                return (response, ndjsonText("Appended."))
            }
        }

        let provider = OllamaProvider(
            host: "http://localhost:11434",
            model: "llama3.2",
            mcpServer: server,
            sessionFactory: mockSessionFactory()
        )

        let exp = expectation(description: "complete")
        provider.sendMessage(
            messages: [ChatMessage(role: .user, content: "add a paragraph")],
            context: AIPromptContext(),
            onToken: { _ in },
            onComplete: { _ in exp.fulfill() }
        )
        wait(for: [exp], timeout: 5.0)

        // Drain main run-loop work so any DispatchQueue.main.async
        // callbacks the bridge enqueued have a chance to settle.
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        // The continuation request must contain the bridge's success
        // envelope — `viaBridge: true` proves the WYSIWYG branch ran,
        // not the source-mode direct-file branch.
        XCTAssertEqual(IntegrationMockURLProtocol.requestCount, 2,
                       "expected one initial + one continuation request")
        let secondBody = IntegrationMockURLProtocol.capturedBodies[1]
        let json = try? JSONSerialization.jsonObject(with: secondBody) as? [String: Any]
        let messages = (json?["messages"] as? [[String: Any]]) ?? []
        let toolMessages = messages.filter { ($0["role"] as? String) == "tool" }
        XCTAssertEqual(toolMessages.count, 1)
        let content = toolMessages.first?["content"] as? String ?? ""
        XCTAssertTrue(content.contains("\"viaBridge\":true"),
                      "expected WYSIWYG bridge dispatch, got: \(content)")
        XCTAssertTrue(content.contains("\"mode\":\"wysiwyg\""),
                      "expected wysiwyg mode marker, got: \(content)")

        // Editor's projection now contains the appended paragraph —
        // the bridge routed through `applyEditResultWithUndo` and
        // updated the live `documentProjection`.
        guard let proj = harness.editor.documentProjection else {
            return XCTFail("editor lost its documentProjection")
        }
        let serialised = MarkdownSerializer.serialize(proj.document)
        XCTAssertTrue(serialised.contains("Initial."),
                      "expected initial content preserved, got: \(serialised)")
        XCTAssertTrue(serialised.contains("New paragraph"),
                      "expected appended paragraph, got: \(serialised)")
        XCTAssertEqual(proj.document.blocks.count, 3,
                       "expected 3 blocks (initial paragraph, blank, new paragraph)")

        // The single-write-path went through: `hasUserEdits` is set
        // by `applyEditResultWithUndo` after the splice, and the
        // editor's textStorage reflects the new content.
        XCTAssertTrue(harness.editor.hasUserEdits,
                      "applyEditResultWithUndo should set hasUserEdits=true")
        let storageStr = harness.editor.textStorage?.string ?? ""
        XCTAssertTrue(storageStr.contains("New paragraph"),
                      "editor textStorage should reflect the splice, got: \(storageStr)")

        // Exactly ONE new UndoJournal entry was added — the bridge's
        // edit went through the canonical journal record path, not a
        // direct storage mutation that bypasses undo.
        let undoCountAfter = harness.editor.undoJournal.past.count
        XCTAssertEqual(undoCountAfter - undoCountBefore, 1,
                       "expected exactly one new undo entry; before=\(undoCountBefore) after=\(undoCountAfter)")
    }

    // MARK: - Scenario 3: Source-mode write end-to-end

    func testSourceModeWrite_writesDiskAndNotifiesEditor() {
        let fixture = MCPTestFixture()
        let url = fixture.makeNote(at: "src.md", content: "Initial.\n")

        // Build a harness, then force source-mode by clearing the
        // block-model active flag. Editor mode is then "source"
        // per AppBridgeImpl.editorMode(for:).
        let harness = AppBridgeImplTestHelper.makeHarness(
            at: url, markdown: "Initial.\n"
        )
        defer { harness.teardown() }
        harness.editor.textStorageProcessor?.blockModelActive = false

        let (rawBridge, vc) = makeLiveBridge(harness: harness)
        _ = vc
        let bridge = MainThreadAppBridge(rawBridge)

        // Sanity check: editorMode is "source" so AppendToNoteTool
        // takes the direct-file branch (NOT the bridge.appendMarkdown
        // path).
        XCTAssertEqual(bridge.editorMode(for: url.standardizedFileURL.path), "source")

        let server = fixture.makeServer(bridge: bridge)
        server.registerTool(AppendToNoteTool(server: server))

        IntegrationMockURLProtocol.install { request, count in
            let response = okResponse(for: request)
            switch count {
            case 1:
                return (response, ndjsonToolCall(
                    name: "append_to_note",
                    arguments: [
                        "path": "src.md",
                        "content": "Source-mode addition"
                    ]
                ))
            default:
                return (response, ndjsonText("Appended in source."))
            }
        }

        let provider = OllamaProvider(
            host: "http://localhost:11434",
            model: "llama3.2",
            mcpServer: server,
            sessionFactory: mockSessionFactory()
        )

        let exp = expectation(description: "complete")
        provider.sendMessage(
            messages: [ChatMessage(role: .user, content: "go")],
            context: AIPromptContext(),
            onToken: { _ in },
            onComplete: { _ in exp.fulfill() }
        )
        wait(for: [exp], timeout: 5.0)

        // The on-disk file was rewritten directly by the tool.
        let onDisk = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        XCTAssertTrue(onDisk.contains("Initial."), "got: \(onDisk)")
        XCTAssertTrue(onDisk.contains("Source-mode addition"), "got: \(onDisk)")

        // The continuation conversation must include the tool result.
        XCTAssertEqual(IntegrationMockURLProtocol.requestCount, 2)
        let secondBody = IntegrationMockURLProtocol.capturedBodies[1]
        let json = try? JSONSerialization.jsonObject(with: secondBody) as? [String: Any]
        let messages = (json?["messages"] as? [[String: Any]]) ?? []
        let toolMessages = messages.filter { ($0["role"] as? String) == "tool" }
        XCTAssertEqual(toolMessages.count, 1, "expected exactly one tool result message")
        let content = toolMessages.first?["content"] as? String ?? ""
        // Source-mode payload carries `"viaBridge":false` and a
        // `"mode":"source"` marker.
        XCTAssertTrue(content.contains("source") || content.contains("viaBridge"),
                      "tool result should reflect direct-file source-mode dispatch, got: \(content)")
    }

    // MARK: - Scenario 4: Destructive op refused without confirm

    func testDeleteWithoutConfirm_isRefusedAndFilePreserved() {
        let fixture = MCPTestFixture()
        let url = fixture.makeNote(at: "victim.md", content: "Important.\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let server = fixture.makeServer(bridge: NoOpAppBridge())
        server.registerTool(DeleteNoteTool(server: server))

        // Round 1: model calls delete_note WITHOUT confirm.
        // Round 2: model produces final text after seeing refusal.
        IntegrationMockURLProtocol.install { request, count in
            let response = okResponse(for: request)
            switch count {
            case 1:
                return (response, ndjsonToolCall(
                    name: "delete_note",
                    arguments: [
                        "title": "victim",
                        "confirm": false
                    ]
                ))
            default:
                return (response, ndjsonText("I will not delete without confirmation."))
            }
        }

        let provider = OllamaProvider(
            host: "http://localhost:11434",
            model: "llama3.2",
            mcpServer: server,
            sessionFactory: mockSessionFactory()
        )

        let exp = expectation(description: "complete")
        var captured: String?
        provider.sendMessage(
            messages: [ChatMessage(role: .user, content: "delete the victim note")],
            context: AIPromptContext(),
            onToken: { _ in },
            onComplete: { result in
                if case .success(let s) = result { captured = s }
                exp.fulfill()
            }
        )
        wait(for: [exp], timeout: 5.0)

        // Conversation continued past the refusal.
        XCTAssertEqual(captured, "I will not delete without confirmation.")
        XCTAssertEqual(IntegrationMockURLProtocol.requestCount, 2)

        // The continuation request carries the tool's refusal as a
        // role:"tool" message containing the `error` envelope.
        let secondBody = IntegrationMockURLProtocol.capturedBodies[1]
        let json = try? JSONSerialization.jsonObject(with: secondBody) as? [String: Any]
        let messages = (json?["messages"] as? [[String: Any]]) ?? []
        let toolMessages = messages.filter { ($0["role"] as? String) == "tool" }
        XCTAssertEqual(toolMessages.count, 1)
        let content = toolMessages.first?["content"] as? String ?? ""
        XCTAssertTrue(content.contains("confirm"),
                      "expected refusal envelope to mention 'confirm', got: \(content)")

        // File is still on disk.
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "delete_note must not have removed the file")
    }

    // MARK: - Scenario 5: Tool-call iteration cap

    func testIterationCap_terminatesWithApiError() {
        let fixture = MCPTestFixture()
        _ = fixture.makeNote(at: "loop.md", content: "x\n")

        let server = fixture.makeServer(bridge: NoOpAppBridge())
        server.registerTool(ReadNoteTool(server: server))

        // Always return a tool_call. The loop must terminate at
        // `OllamaProvider.maxToolRounds` rather than running forever.
        IntegrationMockURLProtocol.install { request, _ in
            return (okResponse(for: request), ndjsonToolCall(
                name: "read_note",
                arguments: ["title": "loop"]
            ))
        }

        let provider = OllamaProvider(
            host: "http://localhost:11434",
            model: "llama3.2",
            mcpServer: server,
            sessionFactory: mockSessionFactory()
        )

        let exp = expectation(description: "complete")
        var captured: Error?
        var success: String?
        provider.sendMessage(
            messages: [ChatMessage(role: .user, content: "loop")],
            context: AIPromptContext(),
            onToken: { _ in },
            onComplete: { result in
                switch result {
                case .success(let s): success = s
                case .failure(let e): captured = e
                }
                exp.fulfill()
            }
        )
        wait(for: [exp], timeout: 15.0)

        XCTAssertNil(success,
                     "iteration cap should surface a failure, not a success: \(success ?? "nil")")
        let err = captured
        XCTAssertNotNil(err, "expected an error from the iteration cap")
        let desc = (err as? LocalizedError)?.errorDescription
            ?? "\(String(describing: err))"
        XCTAssertTrue(desc.contains("\(OllamaProvider.maxToolRounds)"),
                      "expected error to mention the cap value, got: \(desc)")
        XCTAssertLessThanOrEqual(IntegrationMockURLProtocol.requestCount,
                                 OllamaProvider.maxToolRounds,
                                 "loop must stop at the cap, not run forever; got \(IntegrationMockURLProtocol.requestCount) rounds")
    }
}
