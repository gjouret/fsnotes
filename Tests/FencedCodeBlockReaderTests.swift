//
//  FencedCodeBlockReaderTests.swift
//  FSNotesTests
//
//  Phase 12.C.5 — Fenced code block reader port tests.
//

import XCTest
@testable import FSNotes

final class FencedCodeBlockReaderTests: XCTestCase {

    func test_basicBacktickFence_matches() {
        let lines = ["```", "foo", "```"]
        guard let result = FencedCodeBlockReader.read(
            lines: lines, from: 0, trailingNewline: false
        ) else {
            return XCTFail("expected match")
        }
        XCTAssertEqual(result.nextIndex, 3)
        guard case .codeBlock(let language, let content, _) = result.block else {
            return XCTFail("expected codeBlock, got \(result.block)")
        }
        XCTAssertNil(language)
        XCTAssertEqual(content, "foo")
    }

    func test_tildeFence_matches() {
        let lines = ["~~~", "x", "~~~"]
        guard let result = FencedCodeBlockReader.read(
            lines: lines, from: 0, trailingNewline: false
        ) else {
            return XCTFail("expected match")
        }
        guard case .codeBlock(_, let content, let fenceStyle) = result.block else {
            return XCTFail("expected codeBlock")
        }
        XCTAssertEqual(content, "x")
        XCTAssertEqual(fenceStyle.character, .tilde)
    }

    func test_languageInfoString_captured() {
        let lines = ["```swift", "let x = 1", "```"]
        guard let result = FencedCodeBlockReader.read(
            lines: lines, from: 0, trailingNewline: false
        ) else {
            return XCTFail("expected match")
        }
        guard case .codeBlock(let language, _, _) = result.block else {
            return XCTFail("expected codeBlock")
        }
        XCTAssertEqual(language, "swift")
    }

    func test_closeFenceMustBeAtLeastOpenLength() {
        // Open `````, close ``` — too short, doesn't close.
        let lines = ["`````", "x", "```", "y"]
        guard let result = FencedCodeBlockReader.read(
            lines: lines, from: 0, trailingNewline: false
        ) else {
            return XCTFail("expected match")
        }
        guard case .codeBlock(_, let content, _) = result.block else {
            return XCTFail("expected codeBlock")
        }
        // The short ``` is treated as content, not close.
        XCTAssertEqual(content, "x\n```\ny")
    }

    func test_unterminatedFence_extendsToEnd() {
        let lines = ["```", "foo", "bar"]
        guard let result = FencedCodeBlockReader.read(
            lines: lines, from: 0, trailingNewline: false
        ) else {
            return XCTFail("expected match")
        }
        guard case .codeBlock(_, let content, _) = result.block else {
            return XCTFail("expected codeBlock")
        }
        XCTAssertEqual(content, "foo\nbar")
        XCTAssertEqual(result.nextIndex, 3)
    }

    func test_indentStripsLeadingSpaces() {
        // 2-space-indented fence open; content lines should have up to
        // 2 leading spaces stripped.
        let lines = ["  ```", "  foo", "    bar", "  ```"]
        guard let result = FencedCodeBlockReader.read(
            lines: lines, from: 0, trailingNewline: false
        ) else {
            return XCTFail("expected match")
        }
        guard case .codeBlock(_, let content, _) = result.block else {
            return XCTFail("expected codeBlock")
        }
        // First content line had 2 spaces (all stripped → ""+ "foo");
        // second had 4 (2 stripped → "  bar").
        XCTAssertEqual(content, "foo\n  bar")
    }

    func test_backtickFence_rejectsInfoStringWithBacktick() {
        // ```` `f` ``` ` is invalid — info string contains backtick.
        let lines = ["```` `info`", "x", "````"]
        XCTAssertNil(FencedCodeBlockReader.read(
            lines: lines, from: 0, trailingNewline: false
        ))
    }

    func test_notAtFence_returnsNil() {
        let lines = ["paragraph"]
        XCTAssertNil(FencedCodeBlockReader.read(
            lines: lines, from: 0, trailingNewline: false
        ))
    }

    func test_trailingNewlineSkipsEmpty() {
        // `lines.count - 1` empty when input ends with \n. Reader
        // should NOT consume that synthetic empty line as fence content.
        let lines = ["```", "foo", "```", ""]
        guard let result = FencedCodeBlockReader.read(
            lines: lines, from: 0, trailingNewline: true
        ) else {
            return XCTFail("expected match")
        }
        XCTAssertEqual(result.nextIndex, 3)
    }

    func test_endToEnd_viaParse_producesCodeBlock() {
        let doc = MarkdownParser.parse("```js\nlet x = 1;\n```\n")
        XCTAssertEqual(doc.blocks.count, 1)
        guard case .codeBlock(let lang, let content, _) = doc.blocks[0] else {
            return XCTFail("expected codeBlock, got \(doc.blocks)")
        }
        XCTAssertEqual(lang, "js")
        XCTAssertEqual(content, "let x = 1;")
    }
}
