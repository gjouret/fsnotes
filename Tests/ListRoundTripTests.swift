//
//  ListRoundTripTests.swift
//  FSNotesTests
//
//  Round-trip tests for lists. Exercises the hardest case of the
//  block model: nested structure via indentation, preserving the
//  exact source indent + marker + whitespace for byte-equal output.
//
//      serialize(parse(markdown)) == markdown  (byte-equal)
//
//  Covers:
//    - flat unordered lists (dash, star, plus markers)
//    - flat ordered lists (N.  and N) markers)
//    - nested unordered lists (one, two, three levels deep)
//    - mixed nesting (ordered inside unordered, etc.)
//    - edge cases: empty items, tab indentation, markers that LOOK
//      like emphasis or HR (disambiguated by parser rules).
//

import XCTest
@testable import FSNotes

class ListRoundTripTests: XCTestCase {

    private func assertRoundTrip(
        _ markdown: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let doc = MarkdownParser.parse(markdown)
        let out = MarkdownSerializer.serialize(doc)
        XCTAssertEqual(
            out, markdown,
            "round-trip diverged\nexpected: \(quoted(markdown))\nactual:   \(quoted(out))",
            file: file, line: line
        )
    }

    private func quoted(_ s: String) -> String {
        return "\"" + s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
            + "\""
    }

    // MARK: - Flat unordered lists

    func test_roundTrip_singleItem_dash() {
        assertRoundTrip("- a\n")
    }

    func test_roundTrip_singleItem_star() {
        assertRoundTrip("* a\n")
    }

    func test_roundTrip_singleItem_plus() {
        assertRoundTrip("+ a\n")
    }

    func test_roundTrip_threeItems() {
        assertRoundTrip("- a\n- b\n- c\n")
    }

    func test_roundTrip_threeItems_noTrailingNewline() {
        assertRoundTrip("- a\n- b\n- c")
    }

    func test_roundTrip_twoSpaces_afterMarker() {
        assertRoundTrip("-  two spaces\n")
    }

    // MARK: - Flat ordered lists

    func test_roundTrip_orderedDot() {
        assertRoundTrip("1. first\n2. second\n3. third\n")
    }

    func test_roundTrip_orderedParen() {
        assertRoundTrip("1) first\n2) second\n")
    }

    func test_roundTrip_orderedMultiDigit() {
        assertRoundTrip("10. ten\n11. eleven\n")
    }

    // MARK: - Nested unordered

    func test_roundTrip_nestedTwoDeep() {
        assertRoundTrip("- a\n  - b\n  - c\n- d\n")
    }

    func test_roundTrip_nestedThreeDeep() {
        assertRoundTrip("- a\n  - b\n    - c\n  - d\n- e\n")
    }

    func test_roundTrip_fourSpaceIndent() {
        assertRoundTrip("- a\n    - b\n    - c\n")
    }

    // MARK: - Mixed ordered/unordered nesting

    func test_roundTrip_orderedInUnordered() {
        assertRoundTrip("- a\n  1. one\n  2. two\n- b\n")
    }

    func test_roundTrip_unorderedInOrdered() {
        assertRoundTrip("1. a\n  - one\n  - two\n2. b\n")
    }

    // MARK: - Inline emphasis inside items

    func test_roundTrip_boldInItem() {
        assertRoundTrip("- this is **bold** text\n")
    }

    func test_roundTrip_codeInItem() {
        assertRoundTrip("- call `foo()` here\n- and `bar()`\n")
    }

    // MARK: - Empty items

    func test_roundTrip_emptyItem() {
        assertRoundTrip("- \n")
    }

    // MARK: - Lists mixed with other blocks

    func test_roundTrip_listAfterHeading() {
        assertRoundTrip("# Title\n- a\n- b\n")
    }

    func test_roundTrip_listBeforeParagraph() {
        assertRoundTrip("- a\n- b\n\npara\n")
    }

    func test_roundTrip_twoListsSeparatedByBlank() {
        assertRoundTrip("- a\n- b\n\n- c\n- d\n")
    }

    // MARK: - Ambiguity with HR / emphasis

    func test_roundTrip_tripleDash_notAList() {
        // "---" is an HR (future work) or literal text (block model).
        // It MUST NOT parse as a list item (double-marker rejection).
        assertRoundTrip("---\n")
    }

    func test_roundTrip_tripleStar_notAList() {
        assertRoundTrip("***\n")
    }

    // MARK: - Structural parse verification

    func test_parse_flatList() {
        let doc = MarkdownParser.parse("- a\n- b\n")
        guard case .list(let items) = doc.blocks[0] else {
            XCTFail("expected list block"); return
        }
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].marker, "-")
        XCTAssertEqual(items[0].indent, "")
        XCTAssertEqual(items[0].afterMarker, " ")
        XCTAssertEqual(items[0].inline, [.text("a")])
        XCTAssertEqual(items[0].children, [])
        XCTAssertEqual(items[1].inline, [.text("b")])
    }

    func test_parse_nestedList() {
        let doc = MarkdownParser.parse("- a\n  - b\n  - c\n- d\n")
        guard case .list(let items) = doc.blocks[0] else {
            XCTFail("expected list block"); return
        }
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].inline, [.text("a")])
        XCTAssertEqual(items[0].children.count, 2)
        XCTAssertEqual(items[0].children[0].inline, [.text("b")])
        XCTAssertEqual(items[0].children[0].indent, "  ")
        XCTAssertEqual(items[0].children[1].inline, [.text("c")])
        XCTAssertEqual(items[1].inline, [.text("d")])
        XCTAssertEqual(items[1].children, [])
    }

    func test_parse_orderedList() {
        let doc = MarkdownParser.parse("1. a\n2. b\n")
        guard case .list(let items) = doc.blocks[0] else {
            XCTFail("expected list block"); return
        }
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].marker, "1.")
        XCTAssertEqual(items[1].marker, "2.")
    }

    func test_parse_tripleDash_notList() {
        let doc = MarkdownParser.parse("---\n")
        if case .list = doc.blocks[0] {
            XCTFail("`---` must NOT parse as a list")
        }
    }
}
