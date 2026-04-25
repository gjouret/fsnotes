//
//  AIChatPersistence.swift
//  FSNotes
//
//  Per-note conversation history persistence. Phase 4 polish:
//  closing and re-opening a note must restore the chat conversation
//  the user had with it. Conversations are scoped per note (not
//  globally) so chat-about-this-note context doesn't leak between
//  unrelated documents.
//
//  Storage layout:
//    ~/Library/Application Support/FSNotes++/AIChats/<note-id>.json
//
//  `<note-id>` is the SHA-256 hash of the note's standardized URL
//  path, hex-encoded. The hash gives us a stable filesystem-safe
//  identifier without requiring Note to gain a real UUID property,
//  and it's stable across rename/move only when the on-disk path is
//  stable — moving a note to a different folder starts a fresh
//  conversation, which matches the per-note context model.
//
//  This is pure file I/O — no AppKit, no AIChatStore reference. The
//  panel schedules saves through this helper (debounced) and calls
//  `load(noteId:)` when its active note changes. Tests point
//  `directory:` at a temp directory.
//

import Foundation
import CryptoKit

/// Per-note chat persistence. All entry points are static; there's no
/// per-instance state. The default `defaultChatsDirectory()` returns
/// the production path; tests pass an explicit override.
enum AIChatPersistence {

    // MARK: - Filesystem layout

    /// Default user-domain directory for chat files. Mirrors the
    /// `Themes/` layout inside the same `FSNotes++` support folder.
    static func defaultChatsDirectory() -> URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return support
            .appendingPathComponent("FSNotes++")
            .appendingPathComponent("AIChats")
    }

    /// Hash a note's URL path into a stable filesystem-safe id.
    static func noteId(forURL url: URL) -> String {
        let path = url.standardizedFileURL.path
        let data = Data(path.utf8)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Build the file URL for a given note id under the directory.
    static func fileURL(noteId: String, in directory: URL) -> URL {
        return directory.appendingPathComponent("\(noteId).json")
    }

    // MARK: - I/O

    /// Load the persisted conversation for a note, or nil when no
    /// file exists / the file is malformed. A malformed file is
    /// treated as "no history" rather than throwing.
    static func load(noteId: String,
                     directory: URL = AIChatPersistence.defaultChatsDirectory()) -> [ChatMessage]? {
        let url = fileURL(noteId: noteId, in: directory)
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }
        var messages: [ChatMessage] = []
        for entry in array {
            guard let roleRaw = entry["role"] as? String,
                  let role = ChatMessage.Role(rawValue: roleRaw),
                  let content = entry["content"] as? String else {
                continue
            }
            messages.append(ChatMessage(role: role, content: content))
        }
        return messages.isEmpty ? nil : messages
    }

    /// Persist a conversation. Creates the directory as needed.
    /// Errors are swallowed — chat persistence is best-effort, never
    /// blocks the user's typing path.
    @discardableResult
    static func save(noteId: String,
                     messages: [ChatMessage],
                     directory: URL = AIChatPersistence.defaultChatsDirectory()) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: nil
            )
        } catch {
            return false
        }
        let payload: [[String: String]] = messages.map { msg in
            ["role": msg.role.rawValue, "content": msg.content]
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        ) else {
            return false
        }
        let url = fileURL(noteId: noteId, in: directory)
        do {
            try data.write(to: url, options: [.atomic])
            return true
        } catch {
            return false
        }
    }

    /// Delete a persisted conversation. No-op when no file exists.
    @discardableResult
    static func delete(noteId: String,
                       directory: URL = AIChatPersistence.defaultChatsDirectory()) -> Bool {
        let url = fileURL(noteId: noteId, in: directory)
        guard FileManager.default.fileExists(atPath: url.path) else { return true }
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            return false
        }
    }
}

// MARK: - Debounced saver

/// Wraps `AIChatPersistence.save` in a 500ms debounce. Phase 4
/// polish: every accepted assistant turn schedules a save, but a
/// long token stream emits dozens of `.completeResponse` actions
/// during multi-round tool use; debouncing collapses them into one
/// disk write.
///
/// Tests pass `debounceInterval: 0` to make every schedule a
/// synchronous save.
final class AIChatPersistenceDebouncer {

    private let interval: TimeInterval
    private let directory: URL
    private var pendingItem: DispatchWorkItem?
    private let queue: DispatchQueue

    init(debounceInterval: TimeInterval = 0.5,
         directory: URL = AIChatPersistence.defaultChatsDirectory(),
         queue: DispatchQueue = .main) {
        self.interval = debounceInterval
        self.directory = directory
        self.queue = queue
    }

    /// Schedule a save. Cancels any prior pending save — the
    /// debouncer only ever has one save in flight, the most recently
    /// requested one.
    func schedule(noteId: String, messages: [ChatMessage]) {
        pendingItem?.cancel()
        let dir = directory
        if interval <= 0 {
            AIChatPersistence.save(noteId: noteId, messages: messages, directory: dir)
            return
        }
        let item = DispatchWorkItem {
            AIChatPersistence.save(noteId: noteId, messages: messages, directory: dir)
        }
        pendingItem = item
        queue.asyncAfter(deadline: .now() + interval, execute: item)
    }

    /// Cancel any pending save without flushing.
    func cancel() {
        pendingItem?.cancel()
        pendingItem = nil
    }

    /// True iff a save is queued.
    var hasPendingSave: Bool {
        guard let item = pendingItem else { return false }
        return !item.isCancelled
    }
}
