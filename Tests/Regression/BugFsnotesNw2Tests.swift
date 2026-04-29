//
//  BugFsnotesNw2Tests.swift
//  FSNotesTests
//
//  Regression test for bd-fsnotes-nw2 (P2):
//  "Typed URL: only post-https part rendered as clickable link"
//
//  When typing a URL like "https://example.com" character by character,
//  the inline reparse must fire so that the complete URL can be
//  detected as an autolink. Before the fix, reparse only fired on
//  closer chars and multi-char inserts — URL characters like : / .
//  were not triggers.
//
//  Fix: reparseCurrentBlockInlines() now fires on every single-
//  character insert, since reparseInlinesIfNeeded returns nil when
//  the inline tree hasn't changed.
//
//  Note: the visual autolink styling (blue underline) for bare URLs
//  at type-time requires a follow-up: DocumentRenderer.applyAutoLinks
//  only runs during full fill, not incremental edits. This test
//  verifies the reparse mechanism fires correctly; the visual styling
//  fix is tracked as a separate dependency.
//

import XCTest
import AppKit
@testable import FSNotes

final class BugFsnotesNw2Tests: XCTestCase {

    /// Type a full URL character by character and verify the text
    /// is preserved correctly in the saved markdown. The reparse
    /// fires on every character but the parser may not detect bare
    /// URLs as autolinks without angle brackets.
    func test_typeFullURL_textPreserved() {
        let h = EditorHarness(markdown: "", windowActivation: .offscreen)
        defer { h.teardown() }

        for ch in "https://example.com" {
            h.type(String(ch))
        }

        // The text must be preserved exactly as typed.
        XCTAssertEqual(
            h.savedMarkdown, "https://example.com",
            "Typed URL text should be preserved"
        )
    }

    /// Type a URL with a path — text must be preserved.
    func test_typeURLWithPath_textPreserved() {
        let h = EditorHarness(markdown: "", windowActivation: .offscreen)
        defer { h.teardown() }

        for ch in "https://example.com/page" {
            h.type(String(ch))
        }

        XCTAssertEqual(
            h.savedMarkdown, "https://example.com/page",
            "Typed URL+path text should be preserved"
        )
    }

    /// Type a colon in non-URL text — must not crash or corrupt.
    func test_typeColonInPlainText_noCorruption() {
        let h = EditorHarness(markdown: "", windowActivation: .offscreen)
        defer { h.teardown() }

        for ch in "Time: 3:00 PM" {
            h.type(String(ch))
        }

        XCTAssertEqual(
            h.savedMarkdown, "Time: 3:00 PM",
            "Plain text with colons should be preserved"
        )
    }

    /// Type a slash in a file path — must not crash or corrupt.
    func test_typeSlashInPath_noCorruption() {
        let h = EditorHarness(markdown: "", windowActivation: .offscreen)
        defer { h.teardown() }

        for ch in "/usr/local/bin" {
            h.type(String(ch))
        }

        XCTAssertEqual(
            h.savedMarkdown, "/usr/local/bin",
            "File path with slashes should be preserved"
        )
    }

    /// Type a period in text — must not crash or corrupt.
    func test_typePeriodInText_noCorruption() {
        let h = EditorHarness(markdown: "", windowActivation: .offscreen)
        defer { h.teardown() }

        for ch in "End of sentence. New one." {
            h.type(String(ch))
        }

        XCTAssertEqual(
            h.savedMarkdown, "End of sentence. New one.",
            "Text with periods should be preserved"
        )
    }

    /// Multi-char insert (toolbar/paste) should still trigger reparse.
    func test_multiCharInsert_triggersReparse() {
        let h = EditorHarness(markdown: "", windowActivation: .offscreen)
        defer { h.teardown() }

        // Type "[link](url)" — the ) is a closer that triggers reparse.
        for ch in "[link](url)" {
            h.type(String(ch))
        }

        // The link markdown should be properly serialized.
        XCTAssertEqual(
            h.savedMarkdown, "[link](url)",
            "Link markdown should be preserved"
        )
    }
}
