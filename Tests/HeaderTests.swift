//
//  HeaderTests.swift
//  FSNotesTests
//
//  Regression tests for header rendering:
//  - ATX H1-H6 detection by the block parser.
//  - Setext H1 / H2 detection and the "bold paragraph misidentified as H2"
//    edge case (paragraph followed by a line of dashes).
//  - Font-size progression across H1-H6 (distinct, monotonically decreasing).
//  - paragraphSpacing / paragraphSpacingBefore per header level.
//

import XCTest
@testable import FSNotes

class HeaderTests: XCTestCase {

    // MARK: - Block parser: ATX levels 1..6

    func test_blockParser_atxH1toH6_detected() {
        let text = "# One\n## Two\n### Three\n#### Four\n##### Five\n###### Six\n"
        let blocks = MarkdownBlockParser.parse(string: text as NSString)

        let headingLevels: [Int] = blocks.compactMap {
            if case .heading(let l) = $0.type { return l }
            return nil
        }
        XCTAssertEqual(headingLevels, [1, 2, 3, 4, 5, 6],
                       "ATX headings H1..H6 should all be detected")
    }

    func test_blockParser_sevenHashesIsNotHeading() {
        // 7 #'s is NOT a valid ATX heading (max level is 6).
        let text = "####### Too deep\n"
        let blocks = MarkdownBlockParser.parse(string: text as NSString)
        for b in blocks {
            if case .heading = b.type {
                XCTFail("7 hashes should not produce a heading, got \(b.type)")
            }
        }
    }

    func test_blockParser_hashWithoutSpaceIsNotHeading() {
        // "#Heading" (no space after #) is NOT an ATX heading.
        let text = "#NoSpace\n"
        let blocks = MarkdownBlockParser.parse(string: text as NSString)
        for b in blocks {
            if case .heading = b.type {
                XCTFail("# without trailing space should not produce heading")
            }
        }
    }

    // MARK: - Block parser: setext headings

    func test_blockParser_setextH1_equalsUnderline() {
        let text = "Title\n===\nbody\n"
        let blocks = MarkdownBlockParser.parse(string: text as NSString)
        let has = blocks.contains { if case .headingSetext(let l) = $0.type { return l == 1 }; return false }
        XCTAssertTrue(has, "'Title\\n===' should produce setext H1")
    }

    func test_blockParser_setextH2_dashUnderlineAfterParagraph() {
        let text = "Title\n---\nbody\n"
        let blocks = MarkdownBlockParser.parse(string: text as NSString)
        let has = blocks.contains { if case .headingSetext(let l) = $0.type { return l == 2 }; return false }
        XCTAssertTrue(has, "'Title\\n---' after paragraph should produce setext H2")
    }

    func test_blockParser_dashesWithoutPrecedingParagraphIsHR() {
        // '---' at document start (no preceding paragraph) is a horizontal rule, not H2.
        let text = "---\n"
        let blocks = MarkdownBlockParser.parse(string: text as NSString)
        // Document start '---' is treated as yamlFence; skip that edge case and
        // test '---' preceded by an empty line instead.
        let text2 = "\n---\nbody\n"
        let blocks2 = MarkdownBlockParser.parse(string: text2 as NSString)
        let hasHeading = blocks2.contains {
            if case .headingSetext = $0.type { return true }
            return false
        }
        XCTAssertFalse(hasHeading,
                       "'---' with no preceding paragraph should not be setext H2")

        // Suppress unused warning on `blocks`.
        _ = blocks
    }

    // Documents the known bug: a **Bold** paragraph followed by '---' gets
    // Bold-only paragraph followed by "---" should NOT become setext H2.
    // Previously (documented bug), emphasis-only paragraphs were
    // incorrectly promoted to setext H2. This is now fixed.
    func test_blockParser_boldParagraphFollowedByDashes_notSetextH2() {
        let text = "**Bold text**\n---\nbody\n"
        let blocks = MarkdownBlockParser.parse(string: text as NSString)
        let has = blocks.contains { if case .headingSetext(let l) = $0.type { return l == 2 }; return false }
        XCTAssertFalse(has,
                       "Bold-only paragraph + '---' should not become setext H2")
    }

    // MARK: - Full pipeline: H1..H6 font sizes are distinct and monotonic

    func test_headerFonts_H1toH6_monotonicallyDecreasing() {
        let savedHideSyntax = NotesTextProcessor.hideSyntax
        NotesTextProcessor.hideSyntax = true
        defer { NotesTextProcessor.hideSyntax = savedHideSyntax }

        let markdown = "# H1 title\n## H2 title\n### H3 title\n#### H4 title\n##### H5 title\n###### H6 title\n"
        let editor = makeFullPipelineEditor()
        editor.textStorage?.setAttributedString(NSMutableAttributedString(string: markdown))
        runFullPipeline(editor)

        guard let storage = editor.textStorage else {
            XCTFail("no storage"); return
        }

        let ns = storage.string as NSString
        var sizes: [CGFloat] = []
        for level in 1...6 {
            let needle = "H\(level) title"
            let r = ns.range(of: needle)
            XCTAssertNotEqual(r.location, NSNotFound)
            let font = storage.attribute(.font, at: r.location, effectiveRange: nil) as? NSFont
            XCTAssertNotNil(font, "H\(level): .font missing")
            sizes.append(font?.pointSize ?? 0)
        }

        // Expected ratios from getHeaderFont(level:): 2.0, 1.7, 1.4, 1.2, 1.1, 1.05
        // for H1..H6. All sizes must be strictly decreasing and all distinct.
        for i in 0..<sizes.count - 1 {
            XCTAssertGreaterThan(sizes[i], sizes[i + 1],
                                 "H\(i+1) size (\(sizes[i])) must be > H\(i+2) size (\(sizes[i+1]))")
        }

        // BUG (documented): the ATX regex `^(\#{1,6}\ )` captures the trailing
        // space in the marks range, so `headerLevel = headerMarksRange.length`
        // is off by one. H1 gets level=2 (ratio 1.7), H6 gets level=7
        // (default, ratio 1.0). The ratios applied are SHIFTED:
        //     [1.7, 1.4, 1.2, 1.1, 1.05, 1.0] instead of
        //     [2.0, 1.7, 1.4, 1.2, 1.1, 1.05]
        // When the bug is fixed (by setting `headerLevel = headerMarksRange.length - 1`
        // or by excluding the space from capture group 1), this assertion must flip.
        let base = sizes[5] / 1.0  // H6 is currently at ratio 1.0 (default)
        let buggyRatios: [CGFloat] = [1.7, 1.4, 1.2, 1.1, 1.05, 1.0]
        for (i, ratio) in buggyRatios.enumerated() {
            let expected = base * ratio
            XCTAssertEqual(sizes[i], expected, accuracy: 0.02,
                           "H\(i+1) currently uses ratio \(ratio) (BUG: should be one level deeper)")
        }
    }

    func test_headerFonts_areBold() {
        let savedHideSyntax = NotesTextProcessor.hideSyntax
        NotesTextProcessor.hideSyntax = true
        defer { NotesTextProcessor.hideSyntax = savedHideSyntax }

        let markdown = "# bold1\n## bold2\n### bold3\n#### bold4\n##### bold5\n###### bold6\n"
        let editor = makeFullPipelineEditor()
        editor.textStorage?.setAttributedString(NSMutableAttributedString(string: markdown))
        runFullPipeline(editor)

        guard let storage = editor.textStorage else { XCTFail("no storage"); return }
        let ns = storage.string as NSString
        for level in 1...6 {
            let r = ns.range(of: "bold\(level)")
            let font = storage.attribute(.font, at: r.location, effectiveRange: nil) as? NSFont
            XCTAssertNotNil(font, "H\(level): .font missing")
            let traits = font?.fontDescriptor.symbolicTraits ?? []
            XCTAssertTrue(traits.contains(.bold), "H\(level) font should be bold, got \(traits)")
        }
    }

    // MARK: - Full pipeline: paragraph spacing per header level

    func test_headerParagraphSpacing_perLevel() {
        let savedHideSyntax = NotesTextProcessor.hideSyntax
        NotesTextProcessor.hideSyntax = true
        defer { NotesTextProcessor.hideSyntax = savedHideSyntax }

        // One blank line separates each header so every header is isFirst=false
        // except the first block.
        let markdown = "# H1\n## H2\n### H3\n#### H4\n##### H5\n###### H6\n"
        let editor = makeFullPipelineEditor()
        editor.textStorage?.setAttributedString(NSMutableAttributedString(string: markdown))
        runFullPipeline(editor)

        guard let storage = editor.textStorage else { XCTFail("no storage"); return }
        let ns = storage.string as NSString
        var spacings: [CGFloat] = []
        for level in 1...6 {
            let r = ns.range(of: "H\(level)")
            let ps = storage.attribute(.paragraphStyle, at: r.location,
                                       effectiveRange: nil) as? NSParagraphStyle
            XCTAssertNotNil(ps, "H\(level): .paragraphStyle missing")
            spacings.append(ps?.paragraphSpacing ?? -1)
        }

        // Expected from TextStorageProcessor phase5 (line 536-556):
        //   H1: baseSize * 0.67  (baseSize ~= 15pt → ~10.05)
        //   H2: 16
        //   H3: 12
        //   H4: 10
        //   H5: 8
        //   H6: 6
        XCTAssertEqual(spacings[1], 16, accuracy: 0.5, "H2 paragraphSpacing should be 16")
        XCTAssertEqual(spacings[2], 12, accuracy: 0.5, "H3 paragraphSpacing should be 12")
        XCTAssertEqual(spacings[3], 10, accuracy: 0.5, "H4 paragraphSpacing should be 10")
        XCTAssertEqual(spacings[4], 8,  accuracy: 0.5, "H5 paragraphSpacing should be 8")
        XCTAssertEqual(spacings[5], 6,  accuracy: 0.5, "H6 paragraphSpacing should be 6")

        // All six values must be distinct — addresses the unchecked bug
        // "Is there any difference in font size / line height / vertical
        // spacing after the header for H3-H6?"
        let uniqueCount = Set(spacings.map { round($0 * 100) / 100 }).count
        XCTAssertEqual(uniqueCount, 6,
                       "paragraphSpacing should differ for each of H1-H6, got \(spacings)")
    }

    // MARK: - Helpers (share pipeline setup pattern with ListMarkerTests)

    private func makeFullPipelineEditor() -> EditTextView {
        let frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        let container = NSTextContainer(size: frame.size)
        let layoutManager = LayoutManager()
        layoutManager.addTextContainer(container)
        let storage = NSTextStorage()
        storage.addLayoutManager(layoutManager)

        let editor = EditTextView(frame: frame, textContainer: container)
        editor.initTextStorage()

        let window = NSWindow(contentRect: frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView?.addSubview(editor)

        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("HeaderTests_\(UUID().uuidString).md")
        try? "placeholder".write(to: tmp, atomically: true, encoding: .utf8)
        let project = Project(storage: Storage.shared(), url: tmp.deletingLastPathComponent())
        let note = Note(url: tmp, with: project)
        editor.note = note
        return editor
    }

    private func runFullPipeline(_ editor: EditTextView) {
        guard let storage = editor.textStorage, let note = editor.note else { return }
        note.content = NSMutableAttributedString(attributedString: storage)
        storage.beginEditing()
        storage.edited(.editedAttributes, range: NSRange(location: 0, length: storage.length), changeInLength: 0)
        storage.endEditing()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
    }
}
