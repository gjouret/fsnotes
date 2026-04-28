//
//  ListReaderTests.swift
//  FSNotesTests
//
//  Phase 12.C.5 — List reader port tests (per-line classifier).
//

import XCTest
@testable import FSNotes

final class ListReaderTests: XCTestCase {

    // MARK: - parseListLine() — unordered markers

    func test_parse_basicBullet() {
        guard let p = ListReader.parseListLine("- item") else {
            return XCTFail("expected match")
        }
        XCTAssertEqual(p.indent, "")
        XCTAssertEqual(p.marker, "-")
        XCTAssertEqual(p.afterMarker, " ")
        XCTAssertNil(p.checkbox)
        XCTAssertEqual(p.content, "item")
    }

    func test_parse_starBullet() {
        guard let p = ListReader.parseListLine("* item") else {
            return XCTFail("expected match")
        }
        XCTAssertEqual(p.marker, "*")
    }

    func test_parse_plusBullet() {
        guard let p = ListReader.parseListLine("+ item") else {
            return XCTFail("expected match")
        }
        XCTAssertEqual(p.marker, "+")
    }

    func test_parse_indentedBullet() {
        guard let p = ListReader.parseListLine("  - item") else {
            return XCTFail("expected match")
        }
        XCTAssertEqual(p.indent, "  ")
        XCTAssertEqual(p.marker, "-")
    }

    func test_parse_emptyBullet_endOfLine() {
        // CommonMark allows empty list items: "-\n"
        guard let p = ListReader.parseListLine("-") else {
            return XCTFail("expected match")
        }
        XCTAssertEqual(p.marker, "-")
        XCTAssertEqual(p.afterMarker, "")
        XCTAssertEqual(p.content, "")
    }

    func test_parse_emptyBullet_withSpace() {
        guard let p = ListReader.parseListLine("- ") else {
            return XCTFail("expected match")
        }
        XCTAssertEqual(p.marker, "-")
        // Content blank → afterMarker normalised to single space.
        XCTAssertEqual(p.afterMarker, " ")
    }

    // MARK: - parseListLine() — ordered markers

    func test_parse_orderedDot() {
        guard let p = ListReader.parseListLine("1. item") else {
            return XCTFail("expected match")
        }
        XCTAssertEqual(p.marker, "1.")
    }

    func test_parse_orderedParen() {
        guard let p = ListReader.parseListLine("3) item") else {
            return XCTFail("expected match")
        }
        XCTAssertEqual(p.marker, "3)")
    }

    func test_parse_orderedMultiDigit() {
        guard let p = ListReader.parseListLine("123. item") else {
            return XCTFail("expected match")
        }
        XCTAssertEqual(p.marker, "123.")
    }

    func test_parse_orderedTooManyDigits_rejected() {
        // CommonMark caps the digit run at 9.
        XCTAssertNil(ListReader.parseListLine("1234567890. item"))
    }

    // MARK: - parseListLine() — rejections

    func test_parse_rejects_horizontalRuleRun() {
        // A run of the same marker char ("---") is HR-like.
        XCTAssertNil(ListReader.parseListLine("---"))
        XCTAssertNil(ListReader.parseListLine("***"))
        XCTAssertNil(ListReader.parseListLine("+++"))
    }

    func test_parse_rejects_markerWithoutSpaceOrEOL() {
        // "-foo" is not a list (no space after marker).
        XCTAssertNil(ListReader.parseListLine("-foo"))
        XCTAssertNil(ListReader.parseListLine("1.foo"))
    }

    func test_parse_rejects_nonMarkerLines() {
        XCTAssertNil(ListReader.parseListLine("plain text"))
        XCTAssertNil(ListReader.parseListLine(""))
    }

    // MARK: - parseListLine() — checkbox extension

    func test_parse_uncheckedTodo() {
        guard let p = ListReader.parseListLine("- [ ] do this") else {
            return XCTFail("expected match")
        }
        XCTAssertNotNil(p.checkbox)
        XCTAssertEqual(p.checkbox?.text, "[ ]")
        XCTAssertEqual(p.content, "do this")
    }

    func test_parse_checkedTodo() {
        guard let p = ListReader.parseListLine("- [x] done") else {
            return XCTFail("expected match")
        }
        XCTAssertEqual(p.checkbox?.text, "[x]")
    }

    func test_parse_checkedTodoCapitalX() {
        guard let p = ListReader.parseListLine("- [X] done") else {
            return XCTFail("expected match")
        }
        XCTAssertEqual(p.checkbox?.text, "[X]")
    }

    func test_parse_orderedItemWithBracketsIsNotCheckbox() {
        // Checkbox extension only fires for unordered markers.
        guard let p = ListReader.parseListLine("1. [ ] not a todo") else {
            return XCTFail("expected match")
        }
        XCTAssertNil(p.checkbox)
    }

    // MARK: - parseListLine() — indented-code-in-item rule (spec #7)

    func test_parse_indentedCodeAfterTabbyMarker() {
        // Spec #7: `-\t\tfoo` → empty item with continuation containing
        // the indented code line.
        guard let p = ListReader.parseListLine("-\t\tfoo") else {
            return XCTFail("expected match")
        }
        XCTAssertEqual(p.marker, "-")
        // afterMarker collapses to 1 col; remaining cols become the
        // continuation line's indentation.
        XCTAssertEqual(p.afterMarker, " ")
        XCTAssertEqual(p.content, "")
        XCTAssertEqual(p.continuationLines.count, 1)
        XCTAssertTrue(p.continuationLines[0].hasSuffix("foo"))
    }

    // MARK: - listMarkerType()

    func test_markerType_unordered() {
        XCTAssertEqual(ListReader.listMarkerType("-"), "-")
        XCTAssertEqual(ListReader.listMarkerType("*"), "*")
        XCTAssertEqual(ListReader.listMarkerType("+"), "+")
    }

    func test_markerType_orderedDot() {
        XCTAssertEqual(ListReader.listMarkerType("1."), ".")
        XCTAssertEqual(ListReader.listMarkerType("42."), ".")
    }

    func test_markerType_orderedParen() {
        XCTAssertEqual(ListReader.listMarkerType("1)"), ")")
        XCTAssertEqual(ListReader.listMarkerType("99)"), ")")
    }

    // MARK: - isOrderedListMarkerWithNonOneStart()

    func test_orderedNonOneStart_yes() {
        XCTAssertTrue(ListReader.isOrderedListMarkerWithNonOneStart("2."))
        XCTAssertTrue(ListReader.isOrderedListMarkerWithNonOneStart("10."))
        XCTAssertTrue(ListReader.isOrderedListMarkerWithNonOneStart("3)"))
    }

    func test_orderedNonOneStart_oneIsFalse() {
        XCTAssertFalse(ListReader.isOrderedListMarkerWithNonOneStart("1."))
        XCTAssertFalse(ListReader.isOrderedListMarkerWithNonOneStart("1)"))
    }

    func test_orderedNonOneStart_unorderedIsFalse() {
        XCTAssertFalse(ListReader.isOrderedListMarkerWithNonOneStart("-"))
        XCTAssertFalse(ListReader.isOrderedListMarkerWithNonOneStart("*"))
    }

    func test_orderedNonOneStart_invalidIsFalse() {
        XCTAssertFalse(ListReader.isOrderedListMarkerWithNonOneStart(""))
        XCTAssertFalse(ListReader.isOrderedListMarkerWithNonOneStart("abc"))
    }

    // MARK: - End-to-end via MarkdownParser.parse

    func test_endToEnd_simpleBulletList() {
        let doc = MarkdownParser.parse("- a\n- b\n- c\n")
        XCTAssertEqual(doc.blocks.count, 1)
        guard case .list(let items, _) = doc.blocks[0] else {
            return XCTFail("expected list, got \(doc.blocks)")
        }
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items[0].marker, "-")
    }

    func test_endToEnd_orderedList_keepsDotMarker() {
        let doc = MarkdownParser.parse("1. a\n2. b\n")
        guard case .list(let items, _) = doc.blocks[0] else {
            return XCTFail("expected list")
        }
        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(items[0].marker.hasSuffix("."))
    }

    func test_endToEnd_todoList() {
        let doc = MarkdownParser.parse("- [ ] a\n- [x] b\n")
        guard case .list(let items, _) = doc.blocks[0] else {
            return XCTFail("expected list")
        }
        XCTAssertEqual(items.count, 2)
        XCTAssertNotNil(items[0].checkbox)
        XCTAssertNotNil(items[1].checkbox)
    }

    func test_endToEnd_markerFamilyChangeStartsNewList() {
        // CommonMark: a change in bullet char starts a new list.
        let doc = MarkdownParser.parse("- a\n+ b\n")
        XCTAssertEqual(doc.blocks.count, 2)
        guard case .list = doc.blocks[0], case .list = doc.blocks[1] else {
            return XCTFail("expected two separate lists")
        }
    }

    func test_endToEnd_orderedNonOneDoesNotInterruptParagraph() {
        // CommonMark 5.3: ordered list starting at != 1 cannot
        // interrupt a paragraph.
        let doc = MarkdownParser.parse("Hello\n2. world\n")
        XCTAssertEqual(doc.blocks.count, 1)
        guard case .paragraph = doc.blocks[0] else {
            return XCTFail("expected paragraph absorbing the 2. line")
        }
    }
}
