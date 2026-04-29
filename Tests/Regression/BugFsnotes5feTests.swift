//
//  BugFsnotes5feTests.swift
//  FSNotesTests
//
//  Regression test for bd-fsnotes-5fe (P2):
//  "Wikilink click fails with 'no application set to open URL wiki:xyz'"
//
//  Verifies that wikiTarget correctly extracts the note name from
//  wiki: URLs, and that handleWikiLink prevents macOS from trying
//  to open wiki: as a web URL.
//

import XCTest
import AppKit
@testable import FSNotes

final class BugFsnotes5feTests: XCTestCase {

    func test_wikiTarget_extractsFromURL() {
        let url = URL(string: "wiki:MyNote")!
        let target = EditTextView.wikiTarget(from: url)
        XCTAssertEqual(target, "MyNote")
    }

    func test_wikiTarget_extractsFromString() {
        let target = EditTextView.wikiTarget(from: "wiki:MyNote")
        XCTAssertEqual(target, "MyNote")
    }

    func test_wikiTarget_handlesPercentEncoding() {
        let url = URL(string: "wiki:My%20Note")!
        let target = EditTextView.wikiTarget(from: url)
        XCTAssertEqual(target, "My Note")
    }

    func test_wikiTarget_nilForNonWiki() {
        let url = URL(string: "https://example.com")!
        XCTAssertNil(EditTextView.wikiTarget(from: url))
        XCTAssertNil(EditTextView.wikiTarget(from: "notawikilink"))
    }

    func test_wikiTarget_nilForEmpty() {
        XCTAssertNil(EditTextView.wikiTarget(from: "wiki:"))
    }

    func test_handleWikiLink_returnsTrueForWikiURL() {
        // handleWikiLink should return true even without a full app
        // context (no ViewController) to prevent macOS from trying
        // to open wiki: as a web URL.
        let h = EditorHarness(markdown: "text", windowActivation: .offscreen)
        defer { h.teardown() }

        let url = URL(string: "wiki:TestNote")!
        let handled = h.editor.handleWikiLink(url)
        XCTAssertTrue(handled, "handleWikiLink should return true for wiki: URL")
    }
}
