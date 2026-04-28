//
//  BlockEditorAtomicTests.swift
//  FSNotesTests
//
//  Phase 12.B.4 — BlankLine + HorizontalRule + Table editor unit tests.
//

import XCTest
@testable import FSNotes

final class BlockEditorAtomicTests: XCTestCase {

    // MARK: - BlankLineBlockEditor

    func test_blankLine_insert_convertsToParagraph() throws {
        let block = Block.blankLine
        let result = try BlankLineBlockEditor.insert(into: block, offsetInBlock: 0, string: "hello")
        XCTAssertEqual(result, Block.paragraph(inline: [.text("hello")]))
    }

    func test_blankLine_delete_isNoOp() throws {
        let block = Block.blankLine
        let result = try BlankLineBlockEditor.delete(in: block, from: 0, to: 0)
        XCTAssertEqual(result, Block.blankLine)
    }

    func test_blankLine_replace_convertsToParagraph() throws {
        let block = Block.blankLine
        let result = try BlankLineBlockEditor.replace(in: block, from: 0, to: 0, with: "X")
        XCTAssertEqual(result, Block.paragraph(inline: [.text("X")]))
    }

    func test_blankLine_insert_onNonBlankLine_throws() {
        let block = Block.paragraph(inline: [.text("p")])
        XCTAssertThrowsError(try BlankLineBlockEditor.insert(into: block, offsetInBlock: 0, string: "x"))
    }

    // MARK: - HorizontalRuleBlockEditor

    func test_hr_insert_throwsUnsupported() {
        let block = Block.horizontalRule(character: "-", length: 3)
        XCTAssertThrowsError(try HorizontalRuleBlockEditor.insert(into: block, offsetInBlock: 0, string: "x"))
    }

    func test_hr_delete_isNoOp() throws {
        let block = Block.horizontalRule(character: "-", length: 3)
        let result = try HorizontalRuleBlockEditor.delete(in: block, from: 0, to: 0)
        XCTAssertEqual(result, block)
    }

    func test_hr_replace_throwsUnsupported() {
        let block = Block.horizontalRule(character: "*", length: 5)
        XCTAssertThrowsError(try HorizontalRuleBlockEditor.replace(in: block, from: 0, to: 0, with: "X"))
    }

    func test_hr_delete_onNonHr_throws() {
        let block = Block.paragraph(inline: [.text("p")])
        XCTAssertThrowsError(try HorizontalRuleBlockEditor.delete(in: block, from: 0, to: 1))
    }

    // MARK: - TableBlockEditor

    private func sampleTable() -> Block {
        return .table(
            header: [TableCell([.text("A")]), TableCell([.text("B")])],
            alignments: [.none, .none],
            rows: [[TableCell([.text("a")]), TableCell([.text("b")])]],
            columnWidths: nil
        )
    }

    func test_table_insert_throwsUnsupported() {
        let block = sampleTable()
        XCTAssertThrowsError(try TableBlockEditor.insert(into: block, offsetInBlock: 0, string: "x"))
    }

    func test_table_delete_isNoOp() throws {
        let block = sampleTable()
        let result = try TableBlockEditor.delete(in: block, from: 0, to: 0)
        XCTAssertEqual(result, block)
    }

    func test_table_replace_throwsUnsupported() {
        let block = sampleTable()
        XCTAssertThrowsError(try TableBlockEditor.replace(in: block, from: 0, to: 1, with: "X"))
    }

    func test_table_delete_onNonTable_throws() {
        let block = Block.paragraph(inline: [.text("p")])
        XCTAssertThrowsError(try TableBlockEditor.delete(in: block, from: 0, to: 1))
    }
}
