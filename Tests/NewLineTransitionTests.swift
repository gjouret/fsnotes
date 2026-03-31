//
//  NewLineTransitionTests.swift
//  FSNotesTests
//
//  Unit tests for TextFormatter.newLineTransition() — the Return key state machine.
//

import XCTest
@testable import FSNotes

class NewLineTransitionTests: XCTestCase {

    // MARK: - Heading → Body Text

    func test_heading_h1_returns_bodyText() {
        let paragraph = NSAttributedString(string: "# Title\n")
        let result = TextFormatter.newLineTransition(
            paragraph: paragraph, paragraphRange: NSRange(location: 0, length: 8),
            cursorLocation: 7, storageLength: 8)
        XCTAssertEqual(result, .bodyText)
    }

    func test_heading_h2_returns_bodyText() {
        let paragraph = NSAttributedString(string: "## Subtitle\n")
        let result = TextFormatter.newLineTransition(
            paragraph: paragraph, paragraphRange: NSRange(location: 0, length: 12),
            cursorLocation: 11, storageLength: 12)
        XCTAssertEqual(result, .bodyText)
    }

    func test_heading_h3_returns_bodyText() {
        let paragraph = NSAttributedString(string: "### Section\n")
        let result = TextFormatter.newLineTransition(
            paragraph: paragraph, paragraphRange: NSRange(location: 0, length: 12),
            cursorLocation: 11, storageLength: 12)
        XCTAssertEqual(result, .bodyText)
    }

    // MARK: - Unordered List

    func test_bulletDash_continues_list() {
        let paragraph = NSAttributedString(string: "- item\n")
        let result = TextFormatter.newLineTransition(
            paragraph: paragraph, paragraphRange: NSRange(location: 0, length: 7),
            cursorLocation: 6, storageLength: 7)
        XCTAssertEqual(result, .continueUnorderedList(prefix: "- "))
    }

    func test_bulletStar_continues_list() {
        let paragraph = NSAttributedString(string: "* item\n")
        let result = TextFormatter.newLineTransition(
            paragraph: paragraph, paragraphRange: NSRange(location: 0, length: 7),
            cursorLocation: 6, storageLength: 7)
        XCTAssertEqual(result, .continueUnorderedList(prefix: "* "))
    }

    func test_bulletPlus_continues_list() {
        let paragraph = NSAttributedString(string: "+ item\n")
        let result = TextFormatter.newLineTransition(
            paragraph: paragraph, paragraphRange: NSRange(location: 0, length: 7),
            cursorLocation: 6, storageLength: 7)
        XCTAssertEqual(result, .continueUnorderedList(prefix: "+ "))
    }

    func test_emptyBullet_exits_list() {
        let paragraph = NSAttributedString(string: "- \n")
        let range = NSRange(location: 0, length: 3)
        let result = TextFormatter.newLineTransition(
            paragraph: paragraph, paragraphRange: range,
            cursorLocation: 2, storageLength: 3)
        XCTAssertEqual(result, .exitList(paragraphRange: range))
    }

    func test_indentedBullet_continues_with_indent() {
        let paragraph = NSAttributedString(string: "  - nested item\n")
        let result = TextFormatter.newLineTransition(
            paragraph: paragraph, paragraphRange: NSRange(location: 0, length: 16),
            cursorLocation: 15, storageLength: 16)
        XCTAssertEqual(result, .continueUnorderedList(prefix: "  - "))
    }

    // MARK: - Numbered List

    func test_numberedList_increments() {
        let paragraph = NSAttributedString(string: "1. first\n")
        let result = TextFormatter.newLineTransition(
            paragraph: paragraph, paragraphRange: NSRange(location: 0, length: 9),
            cursorLocation: 8, storageLength: 9)
        XCTAssertEqual(result, .continueNumberedList(next: "2. "))
    }

    func test_numberedList_empty_exits() {
        let paragraph = NSAttributedString(string: "3. \n")
        let range = NSRange(location: 0, length: 4)
        let result = TextFormatter.newLineTransition(
            paragraph: paragraph, paragraphRange: range,
            cursorLocation: 3, storageLength: 4)
        XCTAssertEqual(result, .exitList(paragraphRange: range))
    }

    // MARK: - Indentation

    func test_tabIndent_continues() {
        let paragraph = NSAttributedString(string: "\tsome code\n")
        let result = TextFormatter.newLineTransition(
            paragraph: paragraph, paragraphRange: NSRange(location: 0, length: 11),
            cursorLocation: 10, storageLength: 11)
        XCTAssertEqual(result, .continueIndent(prefix: "\t"))
    }

    func test_spaceIndent_continues() {
        let paragraph = NSAttributedString(string: "    indented\n")
        let result = TextFormatter.newLineTransition(
            paragraph: paragraph, paragraphRange: NSRange(location: 0, length: 13),
            cursorLocation: 12, storageLength: 13)
        XCTAssertEqual(result, .continueIndent(prefix: "    "))
    }

    // MARK: - Body Text (default)

    func test_plainText_returns_bodyText() {
        let paragraph = NSAttributedString(string: "Hello world\n")
        let result = TextFormatter.newLineTransition(
            paragraph: paragraph, paragraphRange: NSRange(location: 0, length: 12),
            cursorLocation: 11, storageLength: 12)
        XCTAssertEqual(result, .bodyText)
    }

    func test_emptyLine_returns_bodyText() {
        let paragraph = NSAttributedString(string: "\n")
        let result = TextFormatter.newLineTransition(
            paragraph: paragraph, paragraphRange: NSRange(location: 0, length: 1),
            cursorLocation: 0, storageLength: 1)
        XCTAssertEqual(result, .bodyText)
    }

    // MARK: - Blockquote

    func test_blockquote_continues() {
        let paragraph = NSAttributedString(string: "> quoted text\n")
        let result = TextFormatter.newLineTransition(
            paragraph: paragraph, paragraphRange: NSRange(location: 0, length: 14),
            cursorLocation: 13, storageLength: 14)
        XCTAssertEqual(result, .continueUnorderedList(prefix: "> "))
    }

    func test_emptyBlockquote_exits() {
        let paragraph = NSAttributedString(string: "> \n")
        let range = NSRange(location: 0, length: 3)
        let result = TextFormatter.newLineTransition(
            paragraph: paragraph, paragraphRange: range,
            cursorLocation: 2, storageLength: 3)
        XCTAssertEqual(result, .exitList(paragraphRange: range))
    }

    // MARK: - Integration: Return key applies correct formatting to next line

    /// Data-driven test: set up a line with given text+font, press Return, verify next line's state.
    private func assertReturnProduces(
        lineText: String,
        lineFont: NSFont,
        expectedTypingFontSize: CGFloat,
        expectedTypingBold: Bool,
        expectedContentPrefix: String? = nil,
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 200))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView?.addSubview(textView)

        let attrs: [NSAttributedString.Key: Any] = [.font: lineFont, .foregroundColor: NSColor.textColor]
        textView.textStorage?.setAttributedString(NSAttributedString(string: lineText, attributes: attrs))

        // Cursor at end of content (before trailing newline if present)
        let cursorAt = lineText.hasSuffix("\n") ? lineText.count - 1 : lineText.count
        textView.setSelectedRange(NSRange(location: cursorAt, length: 0))

        let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("test_\(label).md")
        let project = Project(storage: Storage.shared(), url: URL(fileURLWithPath: NSTemporaryDirectory()))
        let note = Note(url: tmpURL, with: project)
        note.type = .Markdown

        let formatter = TextFormatter(textView: textView, note: note)
        formatter.newLine()

        let cursorPos = textView.selectedRange().location
        let typingFont = textView.typingAttributes[.font] as? NSFont
        let storageStr = textView.textStorage?.string ?? ""
        let traits = typingFont?.fontDescriptor.symbolicTraits ?? []

        print("[\(label)] cursor=\(cursorPos) typingFont=\(typingFont?.fontName ?? "nil")@\(typingFont?.pointSize ?? 0) bold=\(traits.contains(.bold)) storage=\"\(storageStr.debugDescription)\"")

        XCTAssertNotNil(typingFont, "\(label): typing attributes should have a font", file: file, line: line)

        if let tf = typingFont {
            XCTAssertEqual(tf.pointSize, expectedTypingFontSize, accuracy: 0.5,
                           "\(label): typing font size \(tf.pointSize) should be \(expectedTypingFontSize)",
                           file: file, line: line)
            XCTAssertEqual(traits.contains(.bold), expectedTypingBold,
                           "\(label): bold should be \(expectedTypingBold) but was \(traits.contains(.bold))",
                           file: file, line: line)
        }

        // Also verify the newline char in storage has the expected font
        if cursorPos > 0 && cursorPos - 1 < (textView.textStorage?.length ?? 0) {
            let nlFont = textView.textStorage?.attribute(.font, at: cursorPos - 1, effectiveRange: nil) as? NSFont
            if let nlf = nlFont {
                XCTAssertEqual(nlf.pointSize, expectedTypingFontSize, accuracy: 0.5,
                               "\(label): newline char font size \(nlf.pointSize) should be \(expectedTypingFontSize)",
                               file: file, line: line)
            }
        }

        // Check if the new line contains expected prefix (cursor may be after it)
        if let prefix = expectedContentPrefix {
            let nsStr = storageStr as NSString
            // Find the last newline before cursor
            let searchRange = NSRange(location: 0, length: cursorPos)
            let nlRange = nsStr.range(of: "\n", options: .backwards, range: searchRange)
            if nlRange.location != NSNotFound {
                let newLineStart = NSMaxRange(nlRange)
                let newLineContent = nsStr.substring(from: newLineStart)
                XCTAssertTrue(newLineContent.hasPrefix(prefix),
                              "\(label): new line should start with \"\(prefix)\" but got \"\(String(newLineContent.prefix(10)))\"",
                              file: file, line: line)
            }
        }
    }

    func test_return_after_h1_resets_to_body() {
        let bodySize = UserDefaultsManagement.noteFont.pointSize
        assertReturnProduces(
            lineText: "# Title\n", lineFont: NSFont.boldSystemFont(ofSize: bodySize * 2),
            expectedTypingFontSize: bodySize, expectedTypingBold: false,
            label: "H1→body")
    }

    func test_return_after_h2_resets_to_body() {
        let bodySize = UserDefaultsManagement.noteFont.pointSize
        assertReturnProduces(
            lineText: "## Subtitle\n", lineFont: NSFont.boldSystemFont(ofSize: bodySize * 1.5),
            expectedTypingFontSize: bodySize, expectedTypingBold: false,
            label: "H2→body")
    }

    /// A/B test: loaded note (known-good) vs Return-after-heading (must match).
    /// Measures line fragment positions in both and asserts they're equal.
    func test_return_after_h2_visual_snapshot() {
        let outputDir = NSHomeDirectory() + "/unit-tests"
        try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

        // Enable WYSIWYG mode for the entire test
        let savedHideSyntax = NotesTextProcessor.hideSyntax
        NotesTextProcessor.hideSyntax = true
        defer { NotesTextProcessor.hideSyntax = savedHideSyntax }

        // --- A: LOADED NOTE with body text after heading (known-good reference) ---
        let editorA = makeFullPipelineEditor()
        editorA.textStorage?.setAttributedString(NSMutableAttributedString(string: "## Bullets\nNow is the time"))
        runFullPipeline(editorA)
        let linesA = measureLineFragments(editorA)
        saveSnapshot(editorA, to: "\(outputDir)/h2_loaded.png")

        // --- B: Same content but loaded with the RESULT of pressing Return ---
        // This is what the markdown looks like after: heading, then Return, then typed text
        let editorB = makeFullPipelineEditor()
        editorB.textStorage?.setAttributedString(NSMutableAttributedString(string: "## Bullets\nI press return\nNow is the time"))
        runFullPipeline(editorB)
        let linesB = measureLineFragments(editorB)
        saveSnapshot(editorB, to: "\(outputDir)/h2_return.png")

        // --- COMPARE ---
        var log = "=== A/B Comparison: Loaded vs Return ===\n"
        log += "A (loaded): \(editorA.textStorage!.string.debugDescription)\n"
        log += "B (return): \(editorB.textStorage!.string.debugDescription)\n\n"

        log += "A lines:\n"
        for l in linesA { log += "  \(l)\n" }
        log += "\nB lines:\n"
        for l in linesB { log += "  \(l)\n" }

        // Find first body text line in each (the line right after heading)
        let bodyLineA = linesA.first { $0.text.contains("Now is") }
        let bodyLineB = linesB.first { $0.text.contains("I press") }

        if let a = bodyLineA, let b = bodyLineB {
            log += "\nBody line A: y=\(String(format: "%.1f", a.y)) height=\(String(format: "%.1f", a.height))\n"
            log += "Body line B: y=\(String(format: "%.1f", b.y)) height=\(String(format: "%.1f", b.height))\n"

            // The body text Y position should be the same — both start at heading bottom
            XCTAssertEqual(a.y, b.y, accuracy: 2.0,
                           "Body text Y position: loaded=\(a.y) vs return=\(b.y) — should match")

            // The gap between heading bottom and body top should be identical
            let headingLineA = linesA.first { $0.text.contains("Bullets") }
            let headingLineB = linesB.first { $0.text.contains("Bullets") }
            if let hA = headingLineA, let hB = headingLineB {
                let gapA = a.y - (hA.y + hA.height)
                let gapB = b.y - (hB.y + hB.height)
                log += "Gap A (heading→body): \(String(format: "%.1f", gapA))\n"
                log += "Gap B (heading→body): \(String(format: "%.1f", gapB))\n"

                XCTAssertEqual(gapA, gapB, accuracy: 2.0,
                               "Gap after heading: loaded=\(gapA) vs return=\(gapB) — must match")
            }
        }

        log += "===\n"
        print(log)
        try? log.write(toFile: "\(outputDir)/h2_ab_compare.log", atomically: true, encoding: .utf8)
    }

    // MARK: - Test Helpers

    struct LineInfo: CustomStringConvertible {
        let charRange: NSRange
        let y: CGFloat
        let height: CGFloat
        let text: String
        var description: String {
            "[\(charRange.location)-\(NSMaxRange(charRange))] y=\(String(format: "%.1f", y)) h=\(String(format: "%.1f", height)) \"\(text.prefix(30).replacingOccurrences(of: "\n", with: "\\n"))\""
        }
    }

    private func makeFullPipelineEditor() -> EditTextView {
        let editor = EditTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView?.addSubview(editor)
        editor.initTextStorage()

        let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test_\(UUID().uuidString).md")
        let project = Project(storage: Storage.shared(), url: URL(fileURLWithPath: NSTemporaryDirectory()))
        let note = Note(url: tmpURL, with: project)
        note.type = .Markdown
        editor.isEditable = true
        editor.note = note
        return editor
    }

    /// Simulate fill(): set note.content, set textStorage, let didProcessEditing run.
    /// Caller must set NotesTextProcessor.hideSyntax before calling.
    private func runFullPipeline(_ editor: EditTextView) {
        guard let storage = editor.textStorage, let note = editor.note else { return }

        // Set note.content to match storage (prevents hash-based early return in process())
        let content = NSMutableAttributedString(attributedString: storage)
        note.content = content
        note.cacheHash = nil  // Force re-processing

        // Re-set to trigger didProcessEditing → process() → highlight + phase4 + phase5
        storage.setAttributedString(content)

        editor.layoutSubtreeIfNeeded()
        editor.display()
    }

    private func measureLineFragments(_ editor: EditTextView) -> [LineInfo] {
        guard let lm = editor.layoutManager, let storage = editor.textStorage else { return [] }
        var lines: [LineInfo] = []
        var glyphIdx = 0
        while glyphIdx < lm.numberOfGlyphs {
            var effectiveRange = NSRange()
            let rect = lm.lineFragmentRect(forGlyphAt: glyphIdx, effectiveRange: &effectiveRange)
            let charRange = lm.characterRange(forGlyphRange: effectiveRange, actualGlyphRange: nil)
            let text = (storage.string as NSString).substring(with: charRange)
            lines.append(LineInfo(charRange: charRange, y: rect.origin.y, height: rect.height, text: text))
            glyphIdx = NSMaxRange(effectiveRange)
        }
        return lines
    }

    private func saveSnapshot(_ editor: EditTextView, to path: String) {
        guard let bitmapRep = editor.bitmapImageRepForCachingDisplay(in: editor.bounds) else { return }
        editor.cacheDisplay(in: editor.bounds, to: bitmapRep)
        if let pngData = bitmapRep.representation(using: .png, properties: [:]) {
            try? pngData.write(to: URL(fileURLWithPath: path))
            print("Saved: \(path)")
        }
    }

    func test_return_after_h3_resets_to_body() {
        let bodySize = UserDefaultsManagement.noteFont.pointSize
        assertReturnProduces(
            lineText: "### Section\n", lineFont: NSFont.boldSystemFont(ofSize: bodySize * 1.17),
            expectedTypingFontSize: bodySize, expectedTypingBold: false,
            label: "H3→body")
    }

    func test_return_after_body_stays_body() {
        let bodySize = UserDefaultsManagement.noteFont.pointSize
        assertReturnProduces(
            lineText: "Plain text\n", lineFont: UserDefaultsManagement.noteFont,
            expectedTypingFontSize: bodySize, expectedTypingBold: false,
            label: "body→body")
    }

    func test_return_after_bullet_continues_bullet() {
        let bodySize = UserDefaultsManagement.noteFont.pointSize
        assertReturnProduces(
            lineText: "- item\n", lineFont: UserDefaultsManagement.noteFont,
            expectedTypingFontSize: bodySize, expectedTypingBold: false,
            expectedContentPrefix: "- ",
            label: "bullet→bullet")
    }

    func test_return_after_numbered_continues_numbered() {
        let bodySize = UserDefaultsManagement.noteFont.pointSize
        assertReturnProduces(
            lineText: "1. first\n", lineFont: UserDefaultsManagement.noteFont,
            expectedTypingFontSize: bodySize, expectedTypingBold: false,
            expectedContentPrefix: "2. ",
            label: "numbered→numbered")
    }
}
