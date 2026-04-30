//
//  BugFsnotes3peTests.swift
//  FSNotesTests
//
//  Regression test for bd-fsnotes-3pe:
//  toolbar formatting over a multi-selection must apply to every
//  selected paragraph/list item, not just the first one.
//

import XCTest
import AppKit
@testable import FSNotes

final class BugFsnotes3peTests: XCTestCase {

    private func markdown(in harness: EditorHarness) -> String {
        let doc = harness.document ?? Document(blocks: [])
        return MarkdownSerializer.serialize(doc)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func test_multiParagraphSelection_headingAppliesToEveryParagraph() {
        let h = EditorHarness(
            markdown: "First\n\nSecond\n\nThird",
            windowActivation: .keyWindow
        )
        defer { h.teardown() }

        let len = h.editor.textStorage?.length ?? 0
        h.editor.setSelectedRange(NSRange(location: 0, length: len))

        XCTAssertTrue(h.editor.changeHeadingLevelViaBlockModel(2))
        XCTAssertEqual(
            markdown(in: h),
            "## First\n\n## Second\n\n## Third"
        )
    }

    func test_multiParagraphSelection_boldAppliesToEveryParagraph() {
        let h = EditorHarness(
            markdown: "First\n\nSecond\n\nThird",
            windowActivation: .keyWindow
        )
        defer { h.teardown() }

        let len = h.editor.textStorage?.length ?? 0
        h.editor.setSelectedRange(NSRange(location: 0, length: len))

        XCTAssertTrue(h.editor.toggleInlineTraitViaBlockModel(.bold))
        XCTAssertEqual(
            markdown(in: h),
            "**First**\n\n**Second**\n\n**Third**"
        )
    }

    func test_multiListItemSelection_italicAppliesToEveryItem() {
        let h = EditorHarness(
            markdown: "- One\n- Two\n- Three",
            windowActivation: .keyWindow
        )
        defer { h.teardown() }

        let len = h.editor.textStorage?.length ?? 0
        h.editor.setSelectedRange(NSRange(location: 0, length: len))

        XCTAssertTrue(h.editor.toggleInlineTraitViaBlockModel(.italic))
        XCTAssertEqual(
            markdown(in: h),
            "- *One*\n- *Two*\n- *Three*"
        )
    }
}
