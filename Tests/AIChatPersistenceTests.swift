//
//  AIChatPersistenceTests.swift
//  FSNotesTests
//
//  Pure file-I/O tests for the per-note conversation persistence
//  helper. Each test points the helper at a fresh temp directory so
//  there's no cross-test bleed and no real `Application Support`
//  pollution. The debouncer is exercised in synchronous mode
//  (debounceInterval=0) so we don't depend on RunLoop timing.
//

import XCTest
@testable import FSNotes

final class AIChatPersistenceTests: XCTestCase {

    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        let unique = "FSNotesAIChatTests-\(UUID().uuidString)"
        tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(unique, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let url = tempDirectory {
            try? FileManager.default.removeItem(at: url)
        }
        super.tearDown()
    }

    // MARK: - noteId derivation

    func test_noteId_isStableForSameURL() {
        let url = URL(fileURLWithPath: "/Users/me/notes/Inbox/Hello.md")
        let a = AIChatPersistence.noteId(forURL: url)
        let b = AIChatPersistence.noteId(forURL: url)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.count, 64, "SHA-256 hex is 64 chars")
    }

    func test_noteId_differsForDifferentURLs() {
        let a = AIChatPersistence.noteId(forURL: URL(fileURLWithPath: "/a.md"))
        let b = AIChatPersistence.noteId(forURL: URL(fileURLWithPath: "/b.md"))
        XCTAssertNotEqual(a, b)
    }

    // MARK: - save / load round-trip

    func test_save_thenLoad_roundTripsConversation() {
        let messages = [
            ChatMessage(role: .user, content: "Hello"),
            ChatMessage(role: .assistant, content: "Hi there!"),
            ChatMessage(role: .user, content: "Goodbye"),
        ]
        XCTAssertTrue(AIChatPersistence.save(noteId: "n1",
                                              messages: messages,
                                              directory: tempDirectory))
        guard let loaded = AIChatPersistence.load(noteId: "n1",
                                                   directory: tempDirectory) else {
            return XCTFail("load returned nil")
        }
        XCTAssertEqual(loaded.count, 3)
        XCTAssertEqual(loaded[0].role, .user)
        XCTAssertEqual(loaded[0].content, "Hello")
        XCTAssertEqual(loaded[1].role, .assistant)
        XCTAssertEqual(loaded[1].content, "Hi there!")
        XCTAssertEqual(loaded[2].role, .user)
        XCTAssertEqual(loaded[2].content, "Goodbye")
    }

    func test_load_returnsNilWhenNoFileExists() {
        let loaded = AIChatPersistence.load(noteId: "ghost",
                                             directory: tempDirectory)
        XCTAssertNil(loaded)
    }

    func test_load_returnsNilOnMalformedJSON() {
        let url = AIChatPersistence.fileURL(noteId: "bad", in: tempDirectory)
        try? "not json at all".write(to: url, atomically: true, encoding: .utf8)
        let loaded = AIChatPersistence.load(noteId: "bad",
                                             directory: tempDirectory)
        XCTAssertNil(loaded)
    }

    func test_load_skipsMalformedEntriesAndKeepsValidOnes() {
        let url = AIChatPersistence.fileURL(noteId: "mixed", in: tempDirectory)
        let json: [[String: Any]] = [
            ["role": "user", "content": "ok"],
            ["role": "ALIEN", "content": "skipme"],
            ["content": "no role"],
            ["role": "assistant", "content": "ok2"],
        ]
        let data = try? JSONSerialization.data(withJSONObject: json)
        try? data?.write(to: url)

        guard let loaded = AIChatPersistence.load(noteId: "mixed",
                                                   directory: tempDirectory) else {
            return XCTFail("expected non-nil")
        }
        XCTAssertEqual(loaded.map(\.content), ["ok", "ok2"])
    }

    func test_save_emptyMessagesWritesEmptyArray() {
        XCTAssertTrue(AIChatPersistence.save(noteId: "empty",
                                              messages: [],
                                              directory: tempDirectory))
        let loaded = AIChatPersistence.load(noteId: "empty",
                                             directory: tempDirectory)
        XCTAssertNil(loaded)
    }

    // MARK: - delete

    func test_delete_removesFile() {
        XCTAssertTrue(AIChatPersistence.save(noteId: "n1",
                                              messages: [ChatMessage(role: .user, content: "x")],
                                              directory: tempDirectory))
        let url = AIChatPersistence.fileURL(noteId: "n1", in: tempDirectory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        XCTAssertTrue(AIChatPersistence.delete(noteId: "n1", directory: tempDirectory))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func test_delete_isNoOpWhenFileMissing() {
        XCTAssertTrue(AIChatPersistence.delete(noteId: "ghost",
                                                directory: tempDirectory))
    }

    // MARK: - Debouncer

    func test_debouncer_synchronousModeWritesImmediately() {
        let d = AIChatPersistenceDebouncer(debounceInterval: 0,
                                           directory: tempDirectory)
        d.schedule(noteId: "sync",
                   messages: [ChatMessage(role: .user, content: "go")])
        let loaded = AIChatPersistence.load(noteId: "sync",
                                             directory: tempDirectory)
        XCTAssertEqual(loaded?.first?.content, "go")
    }

    func test_debouncer_pendingScheduleCanBeCancelled() {
        let d = AIChatPersistenceDebouncer(debounceInterval: 5.0,
                                           directory: tempDirectory)
        d.schedule(noteId: "n1",
                   messages: [ChatMessage(role: .user, content: "hi")])
        XCTAssertTrue(d.hasPendingSave)
        d.cancel()
        XCTAssertFalse(d.hasPendingSave)
    }

    func test_debouncer_repeatedScheduleKeepsLatestOnly() {
        let d = AIChatPersistenceDebouncer(debounceInterval: 0,
                                           directory: tempDirectory)
        d.schedule(noteId: "n1", messages: [ChatMessage(role: .user, content: "v1")])
        d.schedule(noteId: "n1", messages: [ChatMessage(role: .user, content: "v2")])
        d.schedule(noteId: "n1", messages: [ChatMessage(role: .user, content: "v3")])

        let loaded = AIChatPersistence.load(noteId: "n1",
                                             directory: tempDirectory)
        XCTAssertEqual(loaded?.first?.content, "v3")
    }
}
