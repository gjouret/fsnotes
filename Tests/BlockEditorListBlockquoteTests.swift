//
//  BlockEditorListBlockquoteTests.swift
//  FSNotesTests
//
//  Phase 12.B.5 + 12.B.6 — ListBlockEditor + BlockquoteBlockEditor unit tests.
//
//  These editors are thin wrappers around `EditingOps.{insertIntoList,
//  deleteInList, replaceInList}` and the blockquote equivalents, so
//  the deep behavioural pinning lives in `ListEditingFSMTests` (485
//  LoC) and the blockquote round-trip / formatting suites. This file
//  asserts that the wrapper plumbing routes correctly: the right
//  helper is called for each method, and the wrapper traps when given
//  the wrong block kind.
//

import XCTest
@testable import FSNotes

final class BlockEditorListBlockquoteTests: XCTestCase {

    // MARK: - ListBlockEditor

    private func sampleList() -> Block {
        return .list(items: [
            ListItem(
                indent: "", marker: "-", afterMarker: " ", checkbox: nil,
                inline: [.text("first")], children: []
            ),
            ListItem(
                indent: "", marker: "-", afterMarker: " ", checkbox: nil,
                inline: [.text("second")], children: []
            )
        ])
    }

    func test_list_insert_routesThroughHelper() throws {
        let block = sampleList()
        // Insert "X" at offset 2 (inside "first" — between 'i' and 'r' in "first").
        // Prefix is 1 char (the bullet); inline starts at offset 1; offset 2 = inline pos 1.
        let result = try ListBlockEditor.insert(into: block, offsetInBlock: 2, string: "X")
        guard case .list(let items, _) = result else {
            return XCTFail("not a list: \(result)")
        }
        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(items[0].inline.contains { if case .text(let s) = $0 { return s.contains("X") } ; return false })
    }

    func test_list_delete_routesThroughHelper() throws {
        let block = sampleList()
        // Delete one char at offset 2 (the 'i' in "first").
        let result = try ListBlockEditor.delete(in: block, from: 2, to: 3)
        guard case .list(let items, _) = result else {
            return XCTFail("not a list: \(result)")
        }
        // First item's inline should now be "frst" (one char shorter).
        if case .text(let s) = items[0].inline[0] {
            XCTAssertEqual(s, "frst")
        } else {
            XCTFail("inline[0] not text: \(items[0].inline)")
        }
    }

    func test_list_insert_onNonList_throws() {
        let block = Block.paragraph(inline: [.text("p")])
        XCTAssertThrowsError(try ListBlockEditor.insert(into: block, offsetInBlock: 0, string: "x"))
    }

    func test_list_delete_onNonList_throws() {
        let block = Block.paragraph(inline: [.text("p")])
        XCTAssertThrowsError(try ListBlockEditor.delete(in: block, from: 0, to: 1))
    }

    func test_list_replace_onNonList_throws() {
        let block = Block.paragraph(inline: [.text("p")])
        XCTAssertThrowsError(try ListBlockEditor.replace(in: block, from: 0, to: 1, with: "x"))
    }

    // MARK: - BlockquoteBlockEditor

    private func sampleBlockquote() -> Block {
        return .blockquote(lines: [
            BlockquoteLine(prefix: "> ", inline: [.text("hello")]),
            BlockquoteLine(prefix: "> ", inline: [.text("world")])
        ])
    }

    func test_blockquote_insert_routesThroughHelper() throws {
        let block = sampleBlockquote()
        // Insert "X" at offset 2 (inside "hello", line 0). Each line is
        // rendered as inline content joined by "\n" — first line: "hello"
        // (5 chars, offsets 0-4); separator "\n" at 5; second line at 6+.
        // Offset 2 lands in 'l' of "hello".
        let result = try BlockquoteBlockEditor.insert(into: block, offsetInBlock: 2, string: "X")
        guard case .blockquote(let lines) = result else {
            return XCTFail("not a blockquote: \(result)")
        }
        XCTAssertEqual(lines.count, 2)
        let firstRaw = lines[0].inline.compactMap {
            if case .text(let s) = $0 { return s } ; return nil
        }.joined()
        XCTAssertTrue(firstRaw.contains("X"), "X missing from first line: \(firstRaw)")
    }

    func test_blockquote_delete_routesThroughHelper() throws {
        let block = sampleBlockquote()
        // Delete one char at offset 0 (first 'h' of "hello").
        let result = try BlockquoteBlockEditor.delete(in: block, from: 0, to: 1)
        guard case .blockquote(let lines) = result else {
            return XCTFail("not a blockquote: \(result)")
        }
        if case .text(let s) = lines[0].inline.first {
            XCTAssertEqual(s, "ello")
        } else {
            XCTFail("first line inline not text: \(lines[0].inline)")
        }
    }

    func test_blockquote_insert_onNonBlockquote_throws() {
        let block = Block.paragraph(inline: [.text("p")])
        XCTAssertThrowsError(try BlockquoteBlockEditor.insert(into: block, offsetInBlock: 0, string: "x"))
    }

    func test_blockquote_delete_onNonBlockquote_throws() {
        let block = Block.paragraph(inline: [.text("p")])
        XCTAssertThrowsError(try BlockquoteBlockEditor.delete(in: block, from: 0, to: 1))
    }

    func test_blockquote_replace_onNonBlockquote_throws() {
        let block = Block.paragraph(inline: [.text("p")])
        XCTAssertThrowsError(try BlockquoteBlockEditor.replace(in: block, from: 0, to: 1, with: "x"))
    }
}
