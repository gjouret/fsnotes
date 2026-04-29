//
//  BugFsnotesZxrTests.swift
//  FSNotesTests
//
//  Regression test for bd-fsnotes-zxr (P2):
//  "Insert Link toolbar: URL not clickable until app reload"
//
//  The Insert Link button calls wrapInLink which creates a .link
//  inline node. The link should render as clickable immediately.
//

import XCTest
import AppKit
@testable import FSNotes

final class BugFsnotesZxrTests: XCTestCase {

    /// Insert a link at cursor and verify the inline tree has a .link node.
    func test_insertLinkAtCursor_createsLinkInline() {
        let h = EditorHarness(markdown: "text", windowActivation: .offscreen)
        defer { h.teardown() }

        // Position cursor at end
        let len = h.editor.textStorage?.length ?? 0
        h.editor.setSelectedRange(NSRange(location: len, length: 0))

        // Simulate what the toolbar does: wrapInLink with URL from clipboard
        guard let proj = h.editor.documentProjection else {
            XCTFail("no projection"); return
        }
        do {
            let result = try EditingOps.wrapInLink(
                range: NSRange(location: 0, length: 0),
                url: "https://example.com",
                displayText: "https://example.com",
                in: proj
            )
            h.editor.applyBlockModelResult(result, actionName: "Link")

            guard let doc = h.document,
                  doc.blocks.count == 1,
                  case .paragraph(let inlines) = doc.blocks[0]
            else { XCTFail("unexpected block structure"); return }

            // Should have a .link inline
            var foundLink = false
            for inline in inlines {
                if case .link = inline { foundLink = true; break }
            }
            XCTAssertTrue(foundLink, "Expected .link in inline tree. Got: \(inlines)")
        } catch {
            XCTFail("wrapInLink threw: \(error)")
        }
    }

    /// Verify the rendered attributed string has .link attribute after insert.
    func test_insertLinkAtCursor_renderedWithLinkAttribute() {
        let h = EditorHarness(markdown: "text", windowActivation: .offscreen)
        defer { h.teardown() }

        let len = h.editor.textStorage?.length ?? 0
        h.editor.setSelectedRange(NSRange(location: len, length: 0))

        guard let proj = h.editor.documentProjection else {
            XCTFail("no projection"); return
        }
        do {
            let result = try EditingOps.wrapInLink(
                range: NSRange(location: 0, length: 0),
                url: "https://example.com",
                displayText: "https://example.com",
                in: proj
            )
            h.editor.applyBlockModelResult(result, actionName: "Link")

            // Check the textStorage for .link attribute
            guard let storage = h.editor.textStorage,
                  storage.length > 0
            else { XCTFail("empty storage"); return }

            let linkAttr = storage.attribute(
                .link, at: 0, effectiveRange: nil
            )
            XCTAssertNotNil(
                linkAttr,
                "Expected .link attribute on rendered text. " +
                "storage.string: \(storage.string)"
            )
        } catch {
            XCTFail("wrapInLink threw: \(error)")
        }
    }
}
