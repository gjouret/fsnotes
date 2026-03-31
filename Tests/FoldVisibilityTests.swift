//
//  FoldVisibilityTests.swift
//  FSNotesTests
//
//  Tests that folding actually hides ALL visual elements — including
//  InlineTableView subviews. The ghost table bug: folding H2 hides text
//  but the table NSView remains visible because the attachment cell's
//  draw() still gets called or the subview isn't hidden.
//

import XCTest
@testable import FSNotes

class FoldVisibilityTests: XCTestCase {

    /// Build a real EditTextView with LayoutManager and TextStorageProcessor,
    /// load markdown, and return the fully configured editor.
    private func makeEditor(markdown: String) -> EditTextView {
        let textView = EditTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let storage = NSTextStorage()
        let lm = LayoutManager()
        let tc = NSTextContainer(size: NSSize(width: 800, height: 1e7))
        storage.addLayoutManager(lm)
        lm.addTextContainer(tc)
        textView.textContainer = tc

        let processor = TextStorageProcessor()
        processor.editorDelegate = textView
        storage.delegate = processor
        textView.textStorageProcessor = processor
        lm.processor = processor

        // Load content
        storage.setAttributedString(NSAttributedString(string: markdown))
        // Manually populate blocks (process() requires editor?.note which isn't set in tests)
        processor.blocks = MarkdownBlockParser.parse(string: markdown as NSString)

        return textView
    }

    // MARK: - The Ghost Table Bug

    func test_foldH2_hidesTableSubview() {
        // Same as test_toggleFold_mustHideTableSubviews but with H1+H2 structure
        let md = "# Title\nIntro\n## Section\nText\n"
        let editor = makeEditor(markdown: md)
        guard let processor = editor.textStorageProcessor,
              let storage = editor.textStorage else {
            XCTFail("No processor or storage"); return
        }

        // Add a table attachment in the fold range (after H2)
        let tableView = InlineTableView(frame: NSRect(x: 0, y: 50, width: 400, height: 100))
        editor.addSubview(tableView)
        let attachment = NSTextAttachment()
        let cell = InlineTableAttachmentCell(tableView: tableView, size: NSSize(width: 400, height: 100))
        attachment.attachmentCell = cell
        storage.append(NSMutableAttributedString(attributedString: NSAttributedString(attachment: attachment)))
        processor.blocks = MarkdownBlockParser.parse(string: storage.string as NSString)

        guard let h2Idx = processor.headerBlockIndex(at: (md as NSString).range(of: "## Section").location) else {
            XCTFail("No H2 found"); return
        }

        processor.toggleFold(headerBlockIndex: h2Idx, textStorage: storage)
        XCTAssertTrue(processor.blocks[h2Idx].collapsed)
        XCTAssertTrue(tableView.isHidden, "Table subview should be hidden when H2 is folded")
    }

    func test_foldH2_setsAttributeOnContent() {
        let md = "## Section\nContent after header\n"
        let editor = makeEditor(markdown: md)
        guard let processor = editor.textStorageProcessor,
              let storage = editor.textStorage else {
            XCTFail("No processor or storage"); return
        }

        guard let idx = processor.headerBlockIndex(at: 0) else {
            XCTFail("No header"); return
        }

        processor.toggleFold(headerBlockIndex: idx, textStorage: storage)

        // Content after header line should have .foldedContent
        let headerEnd = NSMaxRange((storage.string as NSString).lineRange(for: NSRange(location: 0, length: 0)))
        if headerEnd < storage.length {
            let hasFolded = storage.attribute(.foldedContent, at: headerEnd, effectiveRange: nil) != nil
            XCTAssertTrue(hasFolded, "Content after folded header should have .foldedContent")
        }
    }

    func test_toggleFold_mustHideTableSubviews() {
        // This test ENFORCES that after folding, InlineTableView subviews
        // in the folded range are hidden. This is the bug spec.
        let md = "## Header\nSome text\n"
        let editor = makeEditor(markdown: md)
        guard let processor = editor.textStorageProcessor,
              let storage = editor.textStorage else {
            XCTFail("No processor or storage"); return
        }

        // Simulate a table subview in the fold range
        let tableView = InlineTableView(frame: NSRect(x: 0, y: 50, width: 400, height: 100))
        tableView.isHidden = false
        editor.addSubview(tableView)

        // Create a fake attachment at position in the fold range and link to tableView
        let attachment = NSTextAttachment()
        let cell = InlineTableAttachmentCell(tableView: tableView, size: NSSize(width: 400, height: 100))
        attachment.attachmentCell = cell
        let attStr = NSAttributedString(attachment: attachment)
        storage.append(NSMutableAttributedString(attributedString: attStr))

        // Re-parse blocks
        processor.blocks = MarkdownBlockParser.parse(string: storage.string as NSString)

        guard let idx = processor.headerBlockIndex(at: 0) else {
            XCTFail("No header"); return
        }

        // Fold
        processor.toggleFold(headerBlockIndex: idx, textStorage: storage)

        // THE SPEC: after toggleFold, table subviews in the fold range MUST be hidden
        XCTAssertTrue(tableView.isHidden,
            "BUG: InlineTableView is still visible after folding. " +
            "toggleFold must hide subviews in the fold range.")
    }
}
