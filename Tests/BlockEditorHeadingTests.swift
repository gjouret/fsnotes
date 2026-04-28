//
//  BlockEditorHeadingTests.swift
//  FSNotesTests
//
//  Phase 12.B.2 — HeadingBlockEditor unit tests.
//

import XCTest
@testable import FSNotes

final class BlockEditorHeadingTests: XCTestCase {

    // MARK: - insert

    func test_insert_atEnd_appendsToSuffix() throws {
        let block = Block.heading(level: 2, suffix: "Hello")
        let result = try HeadingBlockEditor.insert(into: block, offsetInBlock: 5, string: "X")
        XCTAssertEqual(result, .heading(level: 2, suffix: "HelloX"))
    }

    func test_insert_atMid_extendsHeading() throws {
        let block = Block.heading(level: 1, suffix: "abcde")
        let result = try HeadingBlockEditor.insert(into: block, offsetInBlock: 2, string: "Z")
        XCTAssertEqual(result, .heading(level: 1, suffix: "abZcde"))
    }

    func test_insert_intoEmptyHeading_landsAfterLeadingWhitespace() throws {
        // Suffix " " (leading space, no visible text). Insert at any
        // offset must land after the leading whitespace.
        let block = Block.heading(level: 1, suffix: " ")
        let result = try HeadingBlockEditor.insert(into: block, offsetInBlock: 0, string: "X")
        XCTAssertEqual(result, .heading(level: 1, suffix: " X"))
    }

    func test_insert_outOfRange_throws() {
        let block = Block.heading(level: 3, suffix: "abc")
        XCTAssertThrowsError(try HeadingBlockEditor.insert(into: block, offsetInBlock: 99, string: "X"))
    }

    func test_insert_onNonHeading_throws() {
        let block = Block.paragraph(inline: [.text("p")])
        XCTAssertThrowsError(try HeadingBlockEditor.insert(into: block, offsetInBlock: 0, string: "x"))
    }

    // MARK: - delete

    func test_delete_zeroLength_returnsBlockUnchanged() throws {
        let block = Block.heading(level: 2, suffix: "Hello")
        let result = try HeadingBlockEditor.delete(in: block, from: 2, to: 2)
        XCTAssertEqual(result, .heading(level: 2, suffix: "Hello"))
    }

    func test_delete_within_removesSubstring() throws {
        let block = Block.heading(level: 2, suffix: "Hello")
        let result = try HeadingBlockEditor.delete(in: block, from: 1, to: 4)
        XCTAssertEqual(result, .heading(level: 2, suffix: "Ho"))
    }

    func test_delete_outOfRange_throws() {
        let block = Block.heading(level: 1, suffix: "abc")
        XCTAssertThrowsError(try HeadingBlockEditor.delete(in: block, from: 0, to: 99))
    }

    func test_delete_onNonHeading_throws() {
        let block = Block.paragraph(inline: [.text("p")])
        XCTAssertThrowsError(try HeadingBlockEditor.delete(in: block, from: 0, to: 1))
    }

    // MARK: - replace

    func test_replace_within_substitutes() throws {
        let block = Block.heading(level: 2, suffix: "Hello")
        let result = try HeadingBlockEditor.replace(in: block, from: 1, to: 4, with: "X")
        XCTAssertEqual(result, .heading(level: 2, suffix: "HXo"))
    }

    func test_replace_onNonHeading_throws() {
        let block = Block.paragraph(inline: [.text("p")])
        XCTAssertThrowsError(try HeadingBlockEditor.replace(in: block, from: 0, to: 1, with: "x"))
    }

    // MARK: - integration: dispatch matches direct call

    func test_integration_insertIntoBlock_headingSwitchMatchesDirectEditor() throws {
        let block = Block.heading(level: 2, suffix: "abc")
        let direct = try HeadingBlockEditor.insert(into: block, offsetInBlock: 1, string: "X")
        let doc = Document(blocks: [block], trailingNewline: false)
        let bodyFont = PlatformFont.systemFont(ofSize: 14)
        let codeFont = PlatformFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        let projection = DocumentProjection(document: doc, bodyFont: bodyFont, codeFont: codeFont)
        // The heading renders as "abc" (no leading whitespace), so
        // storage offset 1 == offsetInBlock 1.
        let result = try EditingOps.insert("X", at: 1, in: projection)
        XCTAssertEqual(
            result.newProjection.document.blocks.first, direct,
            "EditingOps dispatch and HeadingBlockEditor must produce the same block"
        )
    }
}
