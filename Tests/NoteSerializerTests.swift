//
//  NoteSerializerTests.swift
//  FSNotesTests
//
//  Unit tests for NoteSerializer — the save pipeline that converts
//  WYSIWYG attributed strings back to clean markdown for disk.
//

import XCTest
@testable import FSNotes

class NoteSerializerTests: XCTestCase {

    func test_prepareForSave_plainMarkdownCheckbox_unchanged() {
        let attrStr = NSMutableAttributedString(string: "- [ ] Item")
        let prepared = NoteSerializer.prepareForSave(attrStr)

        XCTAssertEqual(prepared.string, "- [ ] Item")
    }

    func test_prepareForSave_restoresRenderedBlocksAndAttachments() {
        let attrStr = NSMutableAttributedString(string: "\u{FFFC}")

        let renderedRange = NSRange(location: 0, length: 1)
        attrStr.addAttribute(.renderedBlockOriginalMarkdown, value: "```mermaid\nA-->B\n```", range: renderedRange)

        let imageURL = URL(fileURLWithPath: "/tmp/example.png")
        let attachment = NSMutableAttributedString(url: imageURL, title: "diagram", path: "assets/example.png")
        attrStr.append(attachment)

        let prepared = NoteSerializer.prepareForSave(attrStr)

        XCTAssertEqual(prepared.string, "```mermaid\nA-->B\n```![diagram](assets/example.png)")
    }

    func test_prepareForSave_plainText_unchanged() {
        let attrStr = NSMutableAttributedString(string: "# Hello\n\nJust text")
        let prepared = NoteSerializer.prepareForSave(attrStr)

        XCTAssertEqual(prepared.string, "# Hello\n\nJust text")
    }
}
