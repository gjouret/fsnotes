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

        // Note: newline character font in storage is NOT checked here — without the full
        // rendering pipeline (NotesTextProcessor + phase5), the newline inherits heading font.
        // The A/B visual test (test_return_after_h2_visual_snapshot) verifies with the real pipeline.

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

        // --- B: LIVE RETURN — load same content, then press Return after heading ---
        let editorB = makeFullPipelineEditor()
        editorB.textStorage?.setAttributedString(NSMutableAttributedString(string: "## Bullets\nNow is the time"))
        runFullPipeline(editorB)
        // Place cursor at end of "## Bullets" (before \n), press Return
        // This is position 10 ("## Bullets" = 10 chars)
        editorB.setSelectedRange(NSRange(location: 10, length: 0))
        let noteB = editorB.note!
        let formatter = TextFormatter(textView: editorB, note: noteB)
        formatter.newLine()
        // Type body text on the new line (simulates what user does after Return)
        editorB.insertText("I press return", replacementRange: editorB.selectedRange())
        // Pump run loop for async renderer work
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        editorB.layoutSubtreeIfNeeded()
        editorB.display()
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

    /// Simulate fill(): set note.content, trigger didProcessEditing pipeline,
    /// then pump the run loop for async renderer work.
    /// Caller must set NotesTextProcessor.hideSyntax before calling.
    private func runFullPipeline(_ editor: EditTextView) {
        guard let storage = editor.textStorage, let note = editor.note else { return }

        // Set note.content to match storage (prevents hash-based early return in process())
        let content = NSMutableAttributedString(attributedString: storage)
        note.content = content
        note.cacheHash = nil  // Force re-processing

        // Re-set to trigger didProcessEditing → process() → highlight + phase4 + phase5
        storage.setAttributedString(content)

        // Pump the main run loop so async renderer work completes
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

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

    /// Verify bullet glyph (•) is actually rendered in the snapshot.
    /// The - marker is hidden by syntax hiding; BulletDrawer must draw • in its place.
    func test_bullet_glyph_rendered_in_snapshot() {
        let outputDir = NSHomeDirectory() + "/unit-tests"
        try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

        let savedHideSyntax = NotesTextProcessor.hideSyntax
        NotesTextProcessor.hideSyntax = true
        defer { NotesTextProcessor.hideSyntax = savedHideSyntax }

        let editor = makeFullPipelineEditor()
        editor.textStorage?.setAttributedString(NSMutableAttributedString(string: "- First item\n- Second item"))
        runFullPipeline(editor)

        // Verify storage still has - (not •)
        let storageStr = editor.textStorage!.string
        XCTAssertTrue(storageStr.contains("- First"), "Storage should contain original '- ' markdown, got: \(storageStr.prefix(20))")
        XCTAssertFalse(storageStr.contains("\u{2022}"), "Storage should NOT contain • (BulletProcessor removed)")

        // Verify .bulletMarker attribute is set on the - characters
        var bulletMarkerCount = 0
        editor.textStorage!.enumerateAttribute(.bulletMarker, in: NSRange(location: 0, length: editor.textStorage!.length)) { value, _, _ in
            if value != nil { bulletMarkerCount += 1 }
        }
        XCTAssertGreaterThan(bulletMarkerCount, 0, "Phase4 should set .bulletMarker attribute on hidden - characters")

        // Render snapshot and check for dark pixels in the bullet area
        guard let bitmapRep = editor.bitmapImageRepForCachingDisplay(in: editor.bounds) else {
            XCTFail("Could not create bitmap")
            return
        }
        editor.cacheDisplay(in: editor.bounds, to: bitmapRep)
        saveSnapshot(editor, to: "\(outputDir)/bullet_glyph.png")

        // Check for dark pixels in the left margin area (where bullets should draw)
        // The indent area is 0..firstLineHeadIndent (~19pt). Bullets draw at ~firstLineHeadIndent.
        let width = bitmapRep.pixelsWide
        let height = bitmapRep.pixelsHigh
        var darkPixelsInBulletArea = 0
        let bulletAreaMaxX = 25  // Check leftmost 25 pixels for bullet glyphs

        for y in 0..<height {
            for x in 0..<bulletAreaMaxX {
                if let color = bitmapRep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) {
                    let brightness = (color.redComponent + color.greenComponent + color.blueComponent) / 3
                    // Dark pixels (text/glyphs) on light background, or light pixels on dark background
                    if color.alphaComponent > 0.5 && (brightness < 0.3 || brightness > 0.7) {
                        darkPixelsInBulletArea += 1
                    }
                }
            }
        }

        print("Bullet glyph test: \(bulletMarkerCount) markers, \(darkPixelsInBulletArea) pixels in bullet area (\(width)x\(height))")
        XCTAssertGreaterThan(darkPixelsInBulletArea, 10,
                             "Bullet area should have visible pixels (• glyph). Found \(darkPixelsInBulletArea) — BulletDrawer may not be rendering.")
    }

    /// All list types (bullet, numbered, todo) should have consistent indentation.
    /// Parameterized: checks headIndent > 0 and firstLineHeadIndent < headIndent for each.
    func test_all_list_types_indent_consistently() {
        let outputDir = NSHomeDirectory() + "/unit-tests"
        try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

        let savedHideSyntax = NotesTextProcessor.hideSyntax
        NotesTextProcessor.hideSyntax = true
        defer { NotesTextProcessor.hideSyntax = savedHideSyntax }

        let listCases: [(name: String, markdown: String)] = [
            ("bullet", "- Bullet item with long text that wraps to next line for indent test"),
            ("numbered", "1. Numbered item with long text that wraps to next line for indent test"),
            ("todo", "- [ ] Task item with long text that wraps to next line for indent test"),
        ]

        var referenceHeadIndent: CGFloat = -1

        for (name, markdown) in listCases {
            let editor = makeFullPipelineEditor()
            editor.textStorage?.setAttributedString(NSMutableAttributedString(string: markdown))
            runFullPipeline(editor)
            saveSnapshot(editor, to: "\(outputDir)/list_\(name).png")

            guard let storage = editor.textStorage, storage.length > 0 else {
                XCTFail("\(name): empty storage")
                continue
            }

            // Log
            let para = storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
            let blocks = editor.textStorageProcessor?.blocks ?? []
            print("[\(name)] headIndent=\(para?.headIndent ?? -1) firstLine=\(para?.firstLineHeadIndent ?? -1) blocks=\(blocks.map { "\($0.type)" }) string=\"\(storage.string.prefix(20))\"")

            // Assert: list paragraph style follows the tabs-as-metadata model.
            //  - firstLineHeadIndent == slotWidth (constant for depth 0)
            //  - headIndent == slotWidth + depth*listStep (so wrapped text aligns
            //    beneath the first-line text at this depth)
            //  - For the test inputs (depth=0, no leading tabs), first == head == slot.
            XCTAssertNotNil(para, "\(name): should have paragraph style")
            if let p = para {
                XCTAssertGreaterThan(p.firstLineHeadIndent, 0,
                                     "\(name): firstLineHeadIndent must be > 0 (marker slot)")
                XCTAssertGreaterThanOrEqual(p.headIndent, p.firstLineHeadIndent,
                                            "\(name): headIndent (\(p.headIndent)) must be >= firstLineHeadIndent (\(p.firstLineHeadIndent))")

                // All list types at the same depth must have identical indents —
                // the slot is now drawer-rendered and depth-independent of block type.
                if referenceHeadIndent < 0 {
                    referenceHeadIndent = p.headIndent
                } else {
                    XCTAssertEqual(p.headIndent, referenceHeadIndent, accuracy: 2.0,
                                   "\(name): headIndent (\(p.headIndent)) should match bullet (\(referenceHeadIndent))")
                }
            }
        }
    }

    /// Regression test for "horizontal gap between glyph and text widens with
    /// depth" (unchecked bug in FSNote++ Bugs & Enhancements).
    ///
    /// Invariants under the tabs-as-metadata model:
    ///   - firstLineHeadIndent == slotWidth (constant for every depth)
    ///   - headIndent == slotWidth + depth*listStep (depth-appropriate wrap)
    ///   - paragraph.tabStops contains per-depth stops
    ///   - The text-start position on the RENDERED line equals slotWidth +
    ///     depth*listStep (i.e. identical gap between marker and text for all
    ///     depths). We verify this by measuring location(forGlyphAt:) on the
    ///     first non-whitespace glyph after the marker.
    func test_list_indent_is_constant_gap_across_depths() {
        let outputDir = NSHomeDirectory() + "/unit-tests"
        try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

        let savedHideSyntax = NotesTextProcessor.hideSyntax
        NotesTextProcessor.hideSyntax = true
        defer { NotesTextProcessor.hideSyntax = savedHideSyntax }

        // Three items at depths 0, 1, 2 using leading tab characters.
        let markdown = "- Level 1\n\t- Level 2\n\t\t- Level 3\n"
        let editor = makeFullPipelineEditor()
        editor.textStorage?.setAttributedString(NSMutableAttributedString(string: markdown))
        runFullPipeline(editor)
        saveSnapshot(editor, to: "\(outputDir)/depth_gap.png")

        guard let storage = editor.textStorage, let lm = editor.layoutManager else {
            XCTFail("missing storage/layoutManager"); return
        }

        let baseSize = UserDefaultsManagement.noteFont.pointSize
        let listStep = baseSize * 4
        let slotWidth = baseSize * 2
        let lineFragmentPadding = editor.textContainer?.lineFragmentPadding ?? 0

        // Locate the first character of each "Level N" text (the 'L').
        let ns = storage.string as NSString
        var depths: [(depth: Int, textLoc: Int)] = []
        for depth in 0...2 {
            let needle = "Level \(depth + 1)"
            let r = ns.range(of: needle)
            XCTAssertNotEqual(r.location, NSNotFound, "could not find '\(needle)'")
            depths.append((depth, r.location))
        }

        for (depth, loc) in depths {
            let para = storage.attribute(.paragraphStyle, at: loc, effectiveRange: nil) as? NSParagraphStyle
            XCTAssertNotNil(para, "depth=\(depth): no paragraph style")
            guard let p = para else { continue }

            // Invariant 1: firstLineHeadIndent is the constant slot.
            XCTAssertEqual(p.firstLineHeadIndent, slotWidth, accuracy: 0.5,
                           "depth=\(depth): firstLineHeadIndent (\(p.firstLineHeadIndent)) should be slotWidth (\(slotWidth))")

            // Invariant 2: headIndent == slotWidth + depth*listStep (wrap alignment).
            let expectedHead = slotWidth + CGFloat(depth) * listStep
            XCTAssertEqual(p.headIndent, expectedHead, accuracy: 0.5,
                           "depth=\(depth): headIndent (\(p.headIndent)) should be \(expectedHead)")

            // Invariant 3: depth-indexed NSTextTab stops exist.
            XCTAssertFalse(p.tabStops.isEmpty, "depth=\(depth): no tabStops on paragraph")
            if depth >= 1, p.tabStops.count >= depth {
                let stop = p.tabStops[depth - 1]
                let expected = slotWidth + CGFloat(depth) * listStep
                XCTAssertEqual(stop.location, expected, accuracy: 0.5,
                               "depth=\(depth): tab stop \(depth) at \(stop.location), expected \(expected)")
            }

            // Invariant 4 (rendered output): the glyph location of 'L' in
            // "Level N" sits at lineFragmentPadding + slotWidth + depth*listStep.
            // This is the critical visual check — tabs must advance the pen
            // through tab stops to land the first text char at the depth position.
            let glyphIdx = lm.glyphIndexForCharacter(at: loc)
            let lineRect = lm.lineFragmentRect(forGlyphAt: glyphIdx, effectiveRange: nil)
            let glyphLoc = lm.location(forGlyphAt: glyphIdx)
            let absX = lineRect.minX + glyphLoc.x
            let expectedAbsX = lineFragmentPadding + expectedHead
            XCTAssertEqual(absX, expectedAbsX, accuracy: 2.0,
                           "depth=\(depth): text ('L') renders at x=\(absX), expected ~\(expectedAbsX) — gap from marker to text must be CONSTANT across depths")
        }

        // Cross-depth: the gap from line-origin to text-start is slotWidth for
        // depth 0. For depth N it's slotWidth + N*listStep. The DIFFERENCE
        // between consecutive depths must equal listStep exactly.
        var prevX: CGFloat = -1
        for (depth, loc) in depths {
            let glyphIdx = lm.glyphIndexForCharacter(at: loc)
            let lineRect = lm.lineFragmentRect(forGlyphAt: glyphIdx, effectiveRange: nil)
            let glyphLoc = lm.location(forGlyphAt: glyphIdx)
            let absX = lineRect.minX + glyphLoc.x
            if prevX >= 0 {
                XCTAssertEqual(absX - prevX, listStep, accuracy: 2.0,
                               "depth \(depth): step from previous depth must be listStep (\(listStep)), got \(absX - prevX)")
            }
            prevX = absX
        }
    }

    /// Simulate CMD+T on a blank line then type characters — all should be visible.
    func test_cmdT_then_type_characters_visible() {
        let outputDir = NSHomeDirectory() + "/unit-tests"
        try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

        let savedHideSyntax = NotesTextProcessor.hideSyntax
        NotesTextProcessor.hideSyntax = true
        defer { NotesTextProcessor.hideSyntax = savedHideSyntax }

        let editor = makeFullPipelineEditor()
        editor.textStorage?.setAttributedString(NSMutableAttributedString(string: "Some text\n"))
        runFullPipeline(editor)

        // Place cursor at end (blank area after \n)
        editor.setSelectedRange(NSRange(location: editor.textStorage!.length, length: 0))

        // Press CMD+T — calls todo() which inserts checkbox
        let formatter = TextFormatter(textView: editor, note: editor.note!)
        formatter.todo()

        // Pump run loop for async operations
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

        let afterTodo = editor.textStorage!.string
        let cursorAfterTodo = editor.selectedRange().location
        print("After CMD+T: storage=\"\(afterTodo.debugDescription)\" cursor=\(cursorAfterTodo)")

        // Log blocks after CMD+T
        if let proc = editor.textStorageProcessor {
            print("Blocks after CMD+T:")
            for (i, b) in proc.blocks.enumerated() {
                print("  block[\(i)]: \(b.type) range=\(b.range)")
            }
        }

        // Now type "Hello" one character at a time
        for (i, ch) in "Hello".enumerated() {
            editor.insertText(String(ch), replacementRange: editor.selectedRange())
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

            let cursorNow = editor.selectedRange().location
            let storageStr = editor.textStorage!.string

            // The typed character should be in the storage
            let typed = String("Hello".prefix(i + 1))
            XCTAssertTrue(storageStr.contains(typed),
                          "After typing '\(ch)' (char \(i+1)): storage should contain \"\(typed)\" but got \"\(storageStr.debugDescription)\"")

            print("  typed '\(ch)': cursor=\(cursorNow) storage=\"\(storageStr.prefix(30).debugDescription)\"")
        }

        // Force layout and snapshot
        editor.layoutSubtreeIfNeeded()
        editor.display()
        saveSnapshot(editor, to: "\(outputDir)/cmdT_type.png")

        // Verify all characters are visible by checking line fragment width
        if let lm = editor.layoutManager {
            let todoLineStart = (editor.textStorage!.string as NSString).range(of: "Hello").location
            if todoLineStart != NSNotFound {
                let glyphIdx = lm.glyphIndexForCharacter(at: todoLineStart)
                let usedRect = lm.lineFragmentUsedRect(forGlyphAt: glyphIdx, effectiveRange: nil)
                print("Todo line usedRect: \(usedRect)")
                // Width should be at least the width of "Hello" in the current font
                let expectedMinWidth = ("Hello" as NSString).size(withAttributes: [.font: UserDefaultsManagement.noteFont]).width
                XCTAssertGreaterThan(usedRect.width, expectedMinWidth * 0.8,
                                     "Todo line should have visible width for 'Hello' text, got \(usedRect.width) (expected >\(expectedMinWidth * 0.8))")
            } else {
                XCTFail("'Hello' not found in storage after typing")
            }
        }

        // Check attributes on the raw markdown checkbox and first few text characters
        let todoStart = (editor.textStorage!.string as NSString).range(of: "- [ ] Hello").location
        if todoStart != NSNotFound {
            for offset in 0..<min(10, editor.textStorage!.length - todoStart) {
                let idx = todoStart + offset
                let attrs = editor.textStorage!.attributes(at: idx, effectiveRange: nil)
                let ch = (editor.textStorage!.string as NSString).substring(with: NSRange(location: idx, length: 1))
                let escaped = ch == " " ? "SPC" : ch
                var summary = ""
                for (key, val) in attrs {
                    if key == .foregroundColor || key == .kern || key == .font || key == .paragraphStyle {
                        summary += " \(key.rawValue)=\(val)"
                    }
                }
                print("  [\(idx)] '\(escaped)'\(summary)")
            }
        }

        // Check paragraph style on the todo line
        let helloLoc = (editor.textStorage!.string as NSString).range(of: "Hello").location
        if helloLoc != NSNotFound {
            let para = editor.textStorage!.attribute(.paragraphStyle, at: helloLoc, effectiveRange: nil) as? NSParagraphStyle
            print("Todo line paragraph: headIndent=\(para?.headIndent ?? -1) firstLine=\(para?.firstLineHeadIndent ?? -1)")
        }
    }

    /// A/B test: bullet continuation — Return after bullet should keep indentation
    func test_return_after_bullet_keeps_indent() {
        let outputDir = NSHomeDirectory() + "/unit-tests"
        try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

        let savedHideSyntax = NotesTextProcessor.hideSyntax
        NotesTextProcessor.hideSyntax = true
        defer { NotesTextProcessor.hideSyntax = savedHideSyntax }

        // A: loaded note with two bullet lines
        let editorA = makeFullPipelineEditor()
        editorA.textStorage?.setAttributedString(NSMutableAttributedString(string: "## Bullets\n- First item\n- Second item"))
        runFullPipeline(editorA)
        let linesA = measureLineFragments(editorA)
        saveSnapshot(editorA, to: "\(outputDir)/bullet_loaded.png")

        // B: loaded note with one bullet, then Return + type
        let editorB = makeFullPipelineEditor()
        editorB.textStorage?.setAttributedString(NSMutableAttributedString(string: "## Bullets\n- First item\n- Second item"))
        runFullPipeline(editorB)
        // Cursor at end of "- First item" — find the position
        let firstItemEnd = (editorB.textStorage!.string as NSString).range(of: "First item").location + "First item".count
        editorB.setSelectedRange(NSRange(location: firstItemEnd, length: 0))
        let noteB = editorB.note!
        let formatter = TextFormatter(textView: editorB, note: noteB)
        formatter.newLine()
        // Pump run loop so async renderer work completes
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        // Do NOT type anything — measure the empty bullet line right after Return
        // This is what the user sees before typing their first character
        editorB.layoutSubtreeIfNeeded()
        editorB.display()
        let linesB = measureLineFragments(editorB)
        saveSnapshot(editorB, to: "\(outputDir)/bullet_return.png")

        // Compare
        var log = "=== Bullet A/B ===\n"
        log += "A: \(editorA.textStorage!.string.debugDescription)\n"
        log += "B: \(editorB.textStorage!.string.debugDescription)\n\n"
        log += "A lines:\n"
        for l in linesA { log += "  \(l)\n" }
        log += "\nB lines:\n"
        for l in linesB { log += "  \(l)\n" }

        // Check paragraph styles for indentation
        if let storageB = editorB.textStorage {
            log += "\nB paragraph styles:\n"
            for i in 0..<storageB.length {
                let ch = (storageB.string as NSString).substring(with: NSRange(location: i, length: 1))
                if ch == "\n" || ch == "-" || ch == "\u{2022}" || ch == "N" {
                    let p = storageB.attribute(.paragraphStyle, at: i, effectiveRange: nil) as? NSParagraphStyle
                    let escaped = ch == "\n" ? "\\n" : ch
                    log += "  [\(i)] '\(escaped)' headIndent=\(p?.headIndent ?? -1) firstLineHeadIndent=\(p?.firstLineHeadIndent ?? -1)\n"
                }
            }
        }

        // Log blocks
        if let processor = editorB.textStorageProcessor {
            log += "\nBlocks after Return:\n"
            for (i, block) in processor.blocks.enumerated() {
                log += "  block[\(i)]: \(block.type) range=\(block.range)\n"
            }
        }

        log += "===\n"
        print(log)
        try? log.write(toFile: "\(outputDir)/bullet_ab.log", atomically: true, encoding: .utf8)

        // The new empty bullet line should have the same headIndent as existing bullets
        if let storageA = editorA.textStorage, let storageB = editorB.textStorage {
            // Find headIndent of first bullet in A
            let firstBulletA = (storageA.string as NSString).range(of: "First").location
            let paraA = storageA.attribute(.paragraphStyle, at: firstBulletA, effectiveRange: nil) as? NSParagraphStyle

            // Find the new bullet's paragraph style — it's the cursor line after Return
            let cursorPos = editorB.selectedRange().location
            // The bullet marker is before the cursor
            let bulletLineStart = max(0, cursorPos - 2)
            let paraB = storageB.attribute(.paragraphStyle, at: bulletLineStart, effectiveRange: nil) as? NSParagraphStyle

            log += "\nIndent comparison:\n"
            log += "  A first bullet: headIndent=\(paraA?.headIndent ?? -1) firstLine=\(paraA?.firstLineHeadIndent ?? -1)\n"
            log += "  B new bullet:   headIndent=\(paraB?.headIndent ?? -1) firstLine=\(paraB?.firstLineHeadIndent ?? -1)\n"
            log += "  B cursor at \(cursorPos), checking pos \(bulletLineStart)\n"

            if let a = paraA, let b = paraB {
                XCTAssertEqual(a.headIndent, b.headIndent, accuracy: 1.0,
                               "Empty bullet headIndent (\(b.headIndent)) should match existing (\(a.headIndent))")
                XCTAssertEqual(a.firstLineHeadIndent, b.firstLineHeadIndent, accuracy: 1.0,
                               "Empty bullet firstLineHeadIndent (\(b.firstLineHeadIndent)) should match existing (\(a.firstLineHeadIndent))")
            }
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
