//
//  MCPServerTests.swift
//  FSNotesTests
//
//  Tests for the MCPServer registry / dispatcher itself, plus the
//  ToolOutput JSON encoding contract and the AppBridge default.
//

import XCTest
@testable import FSNotes

/// Trivial tool that records every call. Used for dispatch tests.
private struct EchoTool: MCPTool {
    let name: String
    let description: String = "echoes its arguments"
    let inputSchema: [String: Any] = ["type": "object", "properties": [:]]

    /// Captured arguments per call. Reference type so we can read
    /// from the test after the async dispatch completes.
    final class Recorder {
        var calls: [[String: Any]] = []
    }

    let recorder: Recorder

    init(name: String = "echo", recorder: Recorder = Recorder()) {
        self.name = name
        self.recorder = recorder
    }

    func execute(input: [String: Any]) async -> ToolOutput {
        recorder.calls.append(input)
        return .success(["echoed": input.count])
    }
}

final class MCPServerTests: XCTestCase {

    func testRegisterAndLookup() {
        let server = MCPServer(storageRoot: nil, appBridge: NoOpAppBridge())
        let tool = EchoTool(name: "alpha")
        server.registerTool(tool)

        XCTAssertNotNil(server.tool(named: "alpha"))
        XCTAssertNil(server.tool(named: "beta"))
        XCTAssertEqual(server.registeredTools.count, 1)
    }

    func testRegisterReplacesOnDuplicateName() {
        let server = MCPServer(storageRoot: nil, appBridge: NoOpAppBridge())
        let first = EchoTool(name: "dup")
        let second = EchoTool(name: "dup")
        server.registerTool(first)
        server.registerTool(second)

        XCTAssertEqual(server.registeredTools.count, 1,
                       "second registration must replace, not append")
    }

    func testHandleToolCallsDispatchesByName() {
        let server = MCPServer(storageRoot: nil, appBridge: NoOpAppBridge())
        let aRecorder = EchoTool.Recorder()
        let bRecorder = EchoTool.Recorder()
        server.registerTool(EchoTool(name: "a", recorder: aRecorder))
        server.registerTool(EchoTool(name: "b", recorder: bRecorder))

        let calls = [
            ToolCall(id: "1", name: "a", arguments: ["x": 1]),
            ToolCall(id: "2", name: "b", arguments: ["y": 2])
        ]
        let semaphore = DispatchSemaphore(value: 0)
        var results: [ToolResult] = []
        Task.detached {
            results = await server.handleToolCalls(calls)
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 5.0)

        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].callID, "1")
        XCTAssertEqual(results[0].toolName, "a")
        XCTAssertTrue(results[0].output.isSuccess)
        XCTAssertEqual(aRecorder.calls.count, 1)
        XCTAssertEqual(bRecorder.calls.count, 1)
    }

    func testUnknownToolReturnsErrorOutput() {
        let server = MCPServer(storageRoot: nil, appBridge: NoOpAppBridge())

        let calls = [ToolCall(id: "x", name: "missing", arguments: [:])]
        let semaphore = DispatchSemaphore(value: 0)
        var results: [ToolResult] = []
        Task.detached {
            results = await server.handleToolCalls(calls)
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 5.0)

        XCTAssertEqual(results.count, 1)
        XCTAssertFalse(results[0].output.isSuccess)
        XCTAssertTrue(results[0].output.errorMessage?.contains("Unknown tool") ?? false)
    }

    func testAmbiguousTitleDisambiguationViaReadNoteTool() {
        let fixture = MCPTestFixture()
        fixture.makeNote(at: "A/Same.md", content: "a\n")
        fixture.makeNote(at: "B/Same.md", content: "b\n")
        let server = fixture.makeServer()
        server.registerTool(ReadNoteTool(server: server))

        let semaphore = DispatchSemaphore(value: 0)
        var results: [ToolResult] = []
        Task.detached {
            results = await server.handleToolCalls([
                ToolCall(id: "1", name: "read_note", arguments: ["title": "Same"])
            ])
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 5.0)

        XCTAssertFalse(results[0].output.isSuccess)
        let msg = results[0].output.errorMessage ?? ""
        XCTAssertTrue(msg.contains("A/Same"), "expected A/Same in disambig: \(msg)")
        XCTAssertTrue(msg.contains("B/Same"), "expected B/Same in disambig: \(msg)")
    }

    func testToolSchemasForLLMShape() {
        let server = MCPServer(storageRoot: nil, appBridge: NoOpAppBridge())
        server.registerTool(EchoTool(name: "alpha"))

        let schemas = server.toolSchemasForLLM()

        XCTAssertEqual(schemas.count, 1)
        XCTAssertEqual(schemas[0]["type"] as? String, "function")
        let fn = schemas[0]["function"] as? [String: Any]
        XCTAssertEqual(fn?["name"] as? String, "alpha")
        XCTAssertEqual(fn?["description"] as? String, "echoes its arguments")
        XCTAssertNotNil(fn?["parameters"])
    }

    // MARK: - ToolOutput / NoOpAppBridge

    func testToolOutputJSONEncodingForSuccess() {
        let out = ToolOutput.success(["a": 1, "b": "two"])
        let json = out.encodeAsJSONString()
        let decoded = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        XCTAssertEqual(decoded?["a"] as? Int, 1)
        XCTAssertEqual(decoded?["b"] as? String, "two")
    }

    func testToolOutputJSONEncodingForError() {
        let out = ToolOutput.error("boom")
        let json = out.encodeAsJSONString()
        let decoded = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        XCTAssertEqual(decoded?["error"] as? String, "boom")
    }

    func testNoOpAppBridgeReturnsExpectedDefaults() {
        let bridge: AppBridge = NoOpAppBridge()
        XCTAssertNil(bridge.currentNotePath())
        XCTAssertFalse(bridge.hasUnsavedChanges(path: "/anything"))
        XCTAssertNil(bridge.editorMode(for: "/anything"))
        XCTAssertNil(bridge.cursorState(for: "/anything"))
        XCTAssertTrue(bridge.requestWriteLock(path: "/anything"))
        // notifyFileChanged should not crash.
        bridge.notifyFileChanged(path: "/anything")
    }
}
