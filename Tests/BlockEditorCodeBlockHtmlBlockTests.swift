//
//  BlockEditorCodeBlockHtmlBlockTests.swift
//  FSNotesTests
//
//  Phase 12.B.3 — CodeBlockBlockEditor + HtmlBlockBlockEditor unit tests.
//

import XCTest
@testable import FSNotes

final class BlockEditorCodeBlockHtmlBlockTests: XCTestCase {

    private func fence(_ language: String? = nil) -> FenceStyle {
        return FenceStyle.canonical(language: language)
    }

    // MARK: - CodeBlockBlockEditor

    func test_codeBlock_insert_atMid_extendsContent() throws {
        let f = fence("swift")
        let block = Block.codeBlock(language: "swift", content: "let x = 1", fence: f)
        let result = try CodeBlockBlockEditor.insert(into: block, offsetInBlock: 4, string: "Z")
        XCTAssertEqual(result, Block.codeBlock(language: "swift", content: "let Zx = 1", fence: f))
    }

    func test_codeBlock_insert_promotesDiagramLanguage() throws {
        // Untagged code block. User types "mermaid\n" + body. The
        // promote helper should upgrade language → "mermaid".
        let block = Block.codeBlock(language: nil, content: "", fence: fence(nil))
        let result = try CodeBlockBlockEditor.insert(into: block, offsetInBlock: 0, string: "mermaid\ngraph TD")
        guard case .codeBlock(let language, _, _) = result else {
            return XCTFail("not a codeBlock: \(result)")
        }
        XCTAssertEqual(language, "mermaid", "language should auto-promote")
    }

    func test_codeBlock_delete_removesSubstring() throws {
        let f = fence(nil)
        let block = Block.codeBlock(language: nil, content: "abcdef", fence: f)
        let result = try CodeBlockBlockEditor.delete(in: block, from: 1, to: 4)
        XCTAssertEqual(result, Block.codeBlock(language: nil, content: "aef", fence: f))
    }

    func test_codeBlock_replace_preservesFence() throws {
        let f = fence("go")
        let block = Block.codeBlock(language: "go", content: "package main", fence: f)
        let result = try CodeBlockBlockEditor.replace(in: block, from: 0, to: 7, with: "module")
        XCTAssertEqual(result, Block.codeBlock(language: "go", content: "module main", fence: f))
    }

    func test_codeBlock_insert_onNonCodeBlock_throws() {
        let block = Block.paragraph(inline: [.text("p")])
        XCTAssertThrowsError(try CodeBlockBlockEditor.insert(into: block, offsetInBlock: 0, string: "x"))
    }

    // MARK: - HtmlBlockBlockEditor

    func test_htmlBlock_insert_extendsRaw() throws {
        let block = Block.htmlBlock(raw: "<div>x</div>")
        let result = try HtmlBlockBlockEditor.insert(into: block, offsetInBlock: 5, string: "Z")
        XCTAssertEqual(result, Block.htmlBlock(raw: "<div>Zx</div>"))
    }

    func test_htmlBlock_delete_removesSubstring() throws {
        let block = Block.htmlBlock(raw: "<div>xy</div>")
        let result = try HtmlBlockBlockEditor.delete(in: block, from: 5, to: 7)
        XCTAssertEqual(result, Block.htmlBlock(raw: "<div></div>"))
    }

    func test_htmlBlock_replace_substitutes() throws {
        let block = Block.htmlBlock(raw: "<div>abc</div>")
        let result = try HtmlBlockBlockEditor.replace(in: block, from: 5, to: 8, with: "X")
        XCTAssertEqual(result, Block.htmlBlock(raw: "<div>X</div>"))
    }

    func test_htmlBlock_insert_onNonHtmlBlock_throws() {
        let block = Block.paragraph(inline: [.text("p")])
        XCTAssertThrowsError(try HtmlBlockBlockEditor.insert(into: block, offsetInBlock: 0, string: "x"))
    }
}
