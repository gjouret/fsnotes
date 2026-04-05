//
//  ListMarkerTests.swift
//  FSNotesTests
//
//  Regression tests for list marker depth variation and stamping:
//  - Bullet glyphs vary with depth (•, ◦, ▪, ▫)
//  - Ordered markers vary with depth (1., a., i.)
//  - Leading-whitespace depth counting (tabs / 4-space groups)
//  - Phase4 stamps .bulletMarker / .orderedMarker / .checkboxMarker with
//    correct depth values so the drawers render the right glyph.
//

import XCTest
@testable import FSNotes

class ListMarkerTests: XCTestCase {

    // MARK: - Pure function: leadingListDepth

    func test_leadingListDepth_tabs() {
        XCTAssertEqual(TextStorageProcessor.leadingListDepth(""), 0)
        XCTAssertEqual(TextStorageProcessor.leadingListDepth("- item"), 0)
        XCTAssertEqual(TextStorageProcessor.leadingListDepth("\t- item"), 1)
        XCTAssertEqual(TextStorageProcessor.leadingListDepth("\t\t- item"), 2)
        XCTAssertEqual(TextStorageProcessor.leadingListDepth("\t\t\t- item"), 3)
    }

    func test_leadingListDepth_4spaces() {
        XCTAssertEqual(TextStorageProcessor.leadingListDepth("    - item"), 1)
        XCTAssertEqual(TextStorageProcessor.leadingListDepth("        - item"), 2)
        XCTAssertEqual(TextStorageProcessor.leadingListDepth("            - item"), 3)
    }

    func test_leadingListDepth_partialSpacesIgnored() {
        // 3 spaces = not a depth level
        XCTAssertEqual(TextStorageProcessor.leadingListDepth("   - item"), 0)
        // 5 spaces = 1 group + 1 leftover
        XCTAssertEqual(TextStorageProcessor.leadingListDepth("     - item"), 1)
    }

    func test_leadingListDepth_mixedTabsAndSpaces() {
        // Tab + 4 spaces = 2
        XCTAssertEqual(TextStorageProcessor.leadingListDepth("\t    - item"), 2)
        // 4 spaces + tab = 2
        XCTAssertEqual(TextStorageProcessor.leadingListDepth("    \t- item"), 2)
    }

    // MARK: - Pure function: alphaMarker

    func test_alphaMarker_singleLetters() {
        XCTAssertEqual(TextStorageProcessor.alphaMarker(1), "a")
        XCTAssertEqual(TextStorageProcessor.alphaMarker(2), "b")
        XCTAssertEqual(TextStorageProcessor.alphaMarker(5), "e")
        XCTAssertEqual(TextStorageProcessor.alphaMarker(26), "z")
    }

    func test_alphaMarker_doubleLetters() {
        XCTAssertEqual(TextStorageProcessor.alphaMarker(27), "aa")
        XCTAssertEqual(TextStorageProcessor.alphaMarker(28), "ab")
        XCTAssertEqual(TextStorageProcessor.alphaMarker(52), "az")
        XCTAssertEqual(TextStorageProcessor.alphaMarker(53), "ba")
    }

    func test_alphaMarker_clampsToOne() {
        XCTAssertEqual(TextStorageProcessor.alphaMarker(0), "a")
        XCTAssertEqual(TextStorageProcessor.alphaMarker(-5), "a")
    }

    // MARK: - Pure function: romanMarker

    func test_romanMarker_smallValues() {
        XCTAssertEqual(TextStorageProcessor.romanMarker(1), "i")
        XCTAssertEqual(TextStorageProcessor.romanMarker(2), "ii")
        XCTAssertEqual(TextStorageProcessor.romanMarker(3), "iii")
        XCTAssertEqual(TextStorageProcessor.romanMarker(4), "iv")
        XCTAssertEqual(TextStorageProcessor.romanMarker(5), "v")
        XCTAssertEqual(TextStorageProcessor.romanMarker(9), "ix")
        XCTAssertEqual(TextStorageProcessor.romanMarker(10), "x")
    }

    func test_romanMarker_largerValues() {
        XCTAssertEqual(TextStorageProcessor.romanMarker(40), "xl")
        XCTAssertEqual(TextStorageProcessor.romanMarker(50), "l")
        XCTAssertEqual(TextStorageProcessor.romanMarker(90), "xc")
        XCTAssertEqual(TextStorageProcessor.romanMarker(100), "c")
    }

    // MARK: - Pure function: orderedMarkerText

    func test_orderedMarkerText_depthZero_isNumeric() {
        XCTAssertEqual(TextStorageProcessor.orderedMarkerText(depth: 0, counter: 1), "1.")
        XCTAssertEqual(TextStorageProcessor.orderedMarkerText(depth: 0, counter: 5), "5.")
        XCTAssertEqual(TextStorageProcessor.orderedMarkerText(depth: 0, counter: 10), "10.")
    }

    func test_orderedMarkerText_depthOne_isAlpha() {
        XCTAssertEqual(TextStorageProcessor.orderedMarkerText(depth: 1, counter: 1), "a.")
        XCTAssertEqual(TextStorageProcessor.orderedMarkerText(depth: 1, counter: 2), "b.")
        XCTAssertEqual(TextStorageProcessor.orderedMarkerText(depth: 1, counter: 5), "e.")
    }

    func test_orderedMarkerText_depthTwo_isRoman() {
        XCTAssertEqual(TextStorageProcessor.orderedMarkerText(depth: 2, counter: 1), "i.")
        XCTAssertEqual(TextStorageProcessor.orderedMarkerText(depth: 2, counter: 2), "ii.")
        XCTAssertEqual(TextStorageProcessor.orderedMarkerText(depth: 2, counter: 4), "iv.")
    }

    func test_orderedMarkerText_depthThreePlus_isRoman() {
        // Depths beyond 2 keep using roman (no further differentiation in the
        // current design — if we later add arabic/upper-roman/etc., this test
        // will need updating).
        XCTAssertEqual(TextStorageProcessor.orderedMarkerText(depth: 3, counter: 1), "i.")
        XCTAssertEqual(TextStorageProcessor.orderedMarkerText(depth: 5, counter: 2), "ii.")
    }

    // MARK: - Full-pipeline: .bulletMarker stamped at every depth

    func test_bulletMarker_stampedWithDepthAcrossLevels() {
        let savedHideSyntax = NotesTextProcessor.hideSyntax
        NotesTextProcessor.hideSyntax = true
        defer { NotesTextProcessor.hideSyntax = savedHideSyntax }

        let markdown = "- Level 0\n\t- Level 1\n\t\t- Level 2\n\t\t\t- Level 3\n"
        let editor = makeFullPipelineEditor()
        editor.textStorage?.setAttributedString(NSMutableAttributedString(string: markdown))
        runFullPipeline(editor)

        guard let storage = editor.textStorage else {
            XCTFail("no storage"); return
        }

        // Scan forward for each "Level N" and verify the MARKER CHAR (the '-'
        // before the leading space) has .bulletMarker == N stamped on it.
        let ns = storage.string as NSString
        for expectedDepth in 0...3 {
            let needle = "Level \(expectedDepth)"
            let textR = ns.range(of: needle)
            XCTAssertNotEqual(textR.location, NSNotFound, "could not find '\(needle)'")

            // The marker char '-' is at textR.location - 2 ("- " before text)
            let markerLoc = textR.location - 2
            XCTAssertGreaterThanOrEqual(markerLoc, 0, "marker loc < 0 for depth \(expectedDepth)")

            let bulletMarker = storage.attribute(.bulletMarker, at: markerLoc,
                                                 effectiveRange: nil) as? Int
            XCTAssertNotNil(bulletMarker,
                            "depth \(expectedDepth): .bulletMarker not stamped at the '-' position")
            XCTAssertEqual(bulletMarker, expectedDepth,
                           "depth \(expectedDepth): .bulletMarker should be \(expectedDepth), got \(String(describing: bulletMarker))")

            let listDepth = storage.attribute(.listDepth, at: markerLoc,
                                              effectiveRange: nil) as? Int
            XCTAssertEqual(listDepth, expectedDepth,
                           "depth \(expectedDepth): .listDepth should be \(expectedDepth), got \(String(describing: listDepth))")
        }
    }

    // MARK: - Full-pipeline: .orderedMarker stamped with depth-appropriate text

    func test_orderedMarker_stampedWithDepthVariation() {
        let savedHideSyntax = NotesTextProcessor.hideSyntax
        NotesTextProcessor.hideSyntax = true
        defer { NotesTextProcessor.hideSyntax = savedHideSyntax }

        // Depth 0: "1.", depth 1: "a.", depth 2: "i."
        let markdown = "1. L0\n\t1. L1\n\t\t1. L2\n"
        let editor = makeFullPipelineEditor()
        editor.textStorage?.setAttributedString(NSMutableAttributedString(string: markdown))
        runFullPipeline(editor)

        guard let storage = editor.textStorage else {
            XCTFail("no storage"); return
        }

        let ns = storage.string as NSString
        let expected: [(depth: Int, label: String, marker: String)] = [
            (0, "L0", "1."),
            (1, "L1", "a."),
            (2, "L2", "i."),
        ]

        for (depth, label, expectedMarker) in expected {
            let textR = ns.range(of: label)
            XCTAssertNotEqual(textR.location, NSNotFound, "could not find '\(label)'")
            // The digit is at the position where marker starts. For "1.", that's
            // textR.location - 3 ("1. " before the label).
            let markerLoc = textR.location - 3
            XCTAssertGreaterThanOrEqual(markerLoc, 0,
                                        "marker loc < 0 for depth \(depth)")

            let marker = storage.attribute(.orderedMarker, at: markerLoc,
                                           effectiveRange: nil) as? String
            XCTAssertNotNil(marker,
                            "depth \(depth): .orderedMarker not stamped for '\(label)'")
            XCTAssertEqual(marker, expectedMarker,
                           "depth \(depth): expected marker '\(expectedMarker)', got '\(String(describing: marker))'")

            let listDepth = storage.attribute(.listDepth, at: markerLoc,
                                              effectiveRange: nil) as? Int
            XCTAssertEqual(listDepth, depth, "depth \(depth): .listDepth mismatch")
        }
    }

    // MARK: - Full-pipeline: .checkboxMarker with depth

    func test_checkboxMarker_stampedWithDepth() {
        let savedHideSyntax = NotesTextProcessor.hideSyntax
        NotesTextProcessor.hideSyntax = true
        defer { NotesTextProcessor.hideSyntax = savedHideSyntax }

        let markdown = "- [ ] Task 0\n\t- [x] Task 1\n\t\t- [ ] Task 2\n"
        let editor = makeFullPipelineEditor()
        editor.textStorage?.setAttributedString(NSMutableAttributedString(string: markdown))
        runFullPipeline(editor)

        guard let storage = editor.textStorage else {
            XCTFail("no storage"); return
        }

        let ns = storage.string as NSString
        let expected: [(depth: Int, label: String, checked: Bool)] = [
            (0, "Task 0", false),
            (1, "Task 1", true),
            (2, "Task 2", false),
        ]

        for (depth, label, expectedChecked) in expected {
            let textR = ns.range(of: label)
            XCTAssertNotEqual(textR.location, NSNotFound, "could not find '\(label)'")

            // Search backwards from label for a char carrying .checkboxMarker.
            var found = false
            var searchLoc = textR.location - 1
            while searchLoc >= 0 && !found {
                if let checked = storage.attribute(.checkboxMarker, at: searchLoc,
                                                    effectiveRange: nil) as? Bool {
                    XCTAssertEqual(checked, expectedChecked,
                                   "depth \(depth): checkbox checked mismatch for '\(label)'")
                    let listDepth = storage.attribute(.listDepth, at: searchLoc,
                                                       effectiveRange: nil) as? Int
                    XCTAssertEqual(listDepth, depth,
                                   "depth \(depth): .listDepth mismatch for '\(label)'")
                    found = true
                }
                searchLoc -= 1
            }
            XCTAssertTrue(found,
                          "depth \(depth): .checkboxMarker not stamped anywhere for '\(label)'")
        }
    }

    // MARK: - Helpers (share pipeline setup pattern with NewLineTransitionTests)

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

        // Create a minimal in-memory Note so fill()/save() don't blow up.
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ListMarkerTests_\(UUID().uuidString).md")
        try? "placeholder".write(to: tmp, atomically: true, encoding: .utf8)
        let project = Project(storage: Storage.shared(), url: tmp.deletingLastPathComponent())
        let note = Note(url: tmp, with: project)
        editor.note = note
        return editor
    }

    private func runFullPipeline(_ editor: EditTextView) {
        guard let storage = editor.textStorage, let note = editor.note else { return }
        note.content = NSMutableAttributedString(attributedString: storage)
        // Trigger didProcessEditing with a no-op edit.
        storage.beginEditing()
        storage.edited(.editedAttributes, range: NSRange(location: 0, length: storage.length), changeInLength: 0)
        storage.endEditing()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
    }
}
