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

    private func range(of needle: String, in haystack: String) -> NSRange {
        return (haystack as NSString).range(of: needle)
    }

    private func toolbarButton(
        tooltip: String,
        in view: NSView
    ) -> NSButton? {
        if let button = view as? NSButton, button.toolTip == tooltip {
            return button
        }
        for subview in view.subviews {
            if let button = toolbarButton(tooltip: tooltip, in: subview) {
                return button
            }
        }
        return nil
    }

    private func clickToolbarButton(
        tooltip: String,
        in harness: EditorHarness,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let toolbar = FormattingToolbar()
        toolbar.frame = NSRect(x: 0, y: 300, width: 900, height: 32)
        harness.editor.window?.contentView?.addSubview(toolbar)
        harness.editor.window?.makeFirstResponder(harness.editor)
        toolbar.updateButtonStates(for: harness.editor)
        guard let button = toolbarButton(tooltip: tooltip, in: toolbar) else {
            XCTFail("Toolbar button not found for \(tooltip)", file: file, line: line)
            return
        }
        button.performClick(nil)
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

    func test_toolbarBoldButton_multiParagraphSelection_boldsEveryParagraph() {
        let h = EditorHarness(
            markdown: "First\n\nSecond\n\nThird",
            windowActivation: .keyWindow
        )
        defer { h.teardown() }

        let len = h.editor.textStorage?.length ?? 0
        h.editor.setSelectedRange(NSRange(location: 0, length: len))

        clickToolbarButton(tooltip: "Bold (Cmd+B)", in: h)
        XCTAssertEqual(
            markdown(in: h),
            "**First**\n\n**Second**\n\n**Third**"
        )
    }

    func test_cmdBAction_singleNewlineParagraphSelection_boldsSelection() {
        let h = EditorHarness(
            markdown: "First\nSecond\nThird",
            windowActivation: .keyWindow
        )
        defer { h.teardown() }

        let len = h.editor.textStorage?.length ?? 0
        h.editor.setSelectedRange(NSRange(location: 0, length: len))

        h.editor.boldMenu(NSObject())
        XCTAssertEqual(
            markdown(in: h),
            "**First\nSecond\nThird**"
        )
    }

    func test_toolbarBoldButton_singleNewlineParagraphSelection_boldsSelection() {
        let h = EditorHarness(
            markdown: "First\nSecond\nThird",
            windowActivation: .keyWindow
        )
        defer { h.teardown() }

        let len = h.editor.textStorage?.length ?? 0
        h.editor.setSelectedRange(NSRange(location: 0, length: len))

        clickToolbarButton(tooltip: "Bold (Cmd+B)", in: h)
        XCTAssertEqual(
            markdown(in: h),
            "**First\nSecond\nThird**"
        )
    }

    func test_toolbarBulletAction_singleNewlineParagraphSelection_listsEveryLine() {
        let h = EditorHarness(
            markdown: "First\nSecond\nThird",
            windowActivation: .keyWindow
        )
        defer { h.teardown() }

        let len = h.editor.textStorage?.length ?? 0
        h.editor.setSelectedRange(NSRange(location: 0, length: len))

        clickToolbarButton(tooltip: "Bullet List", in: h)
        XCTAssertEqual(
            markdown(in: h),
            "- First\n- Second\n- Third"
        )
    }

    func test_toolbarNumberedAction_singleNewlineParagraphSelection_listsEveryLine() {
        let h = EditorHarness(
            markdown: "First\nSecond\nThird",
            windowActivation: .keyWindow
        )
        defer { h.teardown() }

        let len = h.editor.textStorage?.length ?? 0
        h.editor.setSelectedRange(NSRange(location: 0, length: len))

        clickToolbarButton(tooltip: "Numbered List", in: h)
        XCTAssertEqual(
            markdown(in: h),
            "1. First\n1. Second\n1. Third"
        )
    }

    func test_toolbarTodoAction_singleNewlineParagraphSelection_listsEveryLine() {
        let h = EditorHarness(
            markdown: "First\nSecond\nThird",
            windowActivation: .keyWindow
        )
        defer { h.teardown() }

        let len = h.editor.textStorage?.length ?? 0
        h.editor.setSelectedRange(NSRange(location: 0, length: len))

        clickToolbarButton(tooltip: "Checkbox", in: h)
        XCTAssertEqual(
            markdown(in: h),
            "- [ ] First\n- [ ] Second\n- [ ] Third"
        )
    }

    func test_toolbarQuoteAction_singleNewlineParagraphSelection_quotesEveryLine() {
        let h = EditorHarness(
            markdown: "First\nSecond\nThird",
            windowActivation: .keyWindow
        )
        defer { h.teardown() }

        let len = h.editor.textStorage?.length ?? 0
        h.editor.setSelectedRange(NSRange(location: 0, length: len))

        clickToolbarButton(tooltip: "Quote", in: h)
        XCTAssertEqual(
            markdown(in: h),
            "> First\n> Second\n> Third"
        )
    }

    func test_toolbarBulletAction_cursorInSoftLineParagraph_listsCurrentLine() {
        let source = "First\nSecond\nThird"
        let h = EditorHarness(
            markdown: source,
            windowActivation: .keyWindow
        )
        defer { h.teardown() }

        let second = range(of: "Second", in: source)
        h.editor.setSelectedRange(NSRange(location: second.location + 2, length: 0))

        clickToolbarButton(tooltip: "Bullet List", in: h)
        XCTAssertEqual(
            markdown(in: h),
            "First\n\n- Second\n\nThird"
        )
    }

    func test_toolbarQuoteAction_partialSoftLineSelection_quotesTouchedLine() {
        let source = "First\nSecond\nThird"
        let h = EditorHarness(
            markdown: source,
            windowActivation: .keyWindow
        )
        defer { h.teardown() }

        let partial = range(of: "eco", in: source)
        h.editor.setSelectedRange(partial)

        clickToolbarButton(tooltip: "Quote", in: h)
        XCTAssertEqual(
            markdown(in: h),
            "First\n\n> Second\n\nThird"
        )
    }

    func test_headingAction_singleNewlineParagraphSelection_headsEveryLine() {
        let h = EditorHarness(
            markdown: "First\nSecond\nThird",
            windowActivation: .keyWindow
        )
        defer { h.teardown() }

        let len = h.editor.textStorage?.length ?? 0
        h.editor.setSelectedRange(NSRange(location: 0, length: len))

        clickToolbarButton(tooltip: "Heading 2", in: h)
        XCTAssertEqual(
            markdown(in: h),
            "## First\n## Second\n## Third"
        )
    }

    func test_headingAction_partialSoftLineSelection_headsTouchedLine() {
        let source = "First\nSecond\nThird"
        let h = EditorHarness(
            markdown: source,
            windowActivation: .keyWindow
        )
        defer { h.teardown() }

        let partial = range(of: "eco", in: source)
        h.editor.setSelectedRange(partial)

        clickToolbarButton(tooltip: "Heading 2", in: h)
        XCTAssertEqual(
            markdown(in: h),
            "First\n## Second\nThird"
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

    func test_toolbarBoldButton_afterBulletConversion_boldsEveryItem() {
        let h = EditorHarness(
            markdown: "First\nSecond\nThird",
            windowActivation: .keyWindow
        )
        defer { h.teardown() }

        var len = h.editor.textStorage?.length ?? 0
        h.editor.setSelectedRange(NSRange(location: 0, length: len))
        h.editor.bulletListMenu(NSObject())
        len = h.editor.textStorage?.length ?? 0
        h.editor.setSelectedRange(NSRange(location: 0, length: len))

        clickToolbarButton(tooltip: "Bold (Cmd+B)", in: h)
        XCTAssertEqual(
            markdown(in: h),
            "- **First**\n- **Second**\n- **Third**"
        )
    }
}
