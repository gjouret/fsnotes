//
//  RenderingCorrectnessTests.swift
//  FSNotesTests
//
//  Validates that the block-model rendering pipeline produces correct
//  visual output and maintains projection consistency after edits.
//

import XCTest
@testable import FSNotes

/// Tests that validate the visual rendering pipeline:
/// - Document → NSAttributedString produces correct displayed text
/// - Block spans align with rendered output
/// - Storage/projection consistency after every edit
/// - Splice ranges are always valid
class RenderingCorrectnessTests: XCTestCase {
    
    // MARK: - Projection Consistency Tests
    
    /// After every edit, storage.length must equal projection.attributed.length
    func testAllEditOperationsMaintainStorageProjectionConsistency() throws {
        let testCases: [(String, (DocumentProjection) throws -> EditResult)] = [
            ("insert text", { try EditingOps.insert("Hello", at: 0, in: $0) }),
            ("insert space", { try EditingOps.insert(" ", at: 0, in: $0) }),
            ("insert newline in paragraph", { try EditingOps.insert("\n", at: 3, in: $0) }),
        ]
        
        for (name, operation) in testCases {
            let doc = Document(blocks: [.paragraph(inline: [.text("Test")])], trailingNewline: false)
            let projection = DocumentProjection(document: doc, bodyFont: testFont(), codeFont: testFont())
            
            let result = try operation(projection)
            
            // Splice replacement length must match what we're replacing
            let oldLength = result.spliceRange.length
            let newLength = result.spliceReplacement.length
            let expectedNewTotal = projection.attributed.length - oldLength + newLength
            
            XCTAssertEqual(
                result.newProjection.attributed.length,
                expectedNewTotal,
                "\(name): new projection length mismatch after splice"
            )
            
            // All block spans must be within bounds
            for (i, span) in result.newProjection.blockSpans.enumerated() {
                XCTAssertTrue(
                    span.location >= 0,
                    "\(name): block \(i) span starts at negative location"
                )
                XCTAssertTrue(
                    span.location + span.length <= result.newProjection.attributed.length,
                    "\(name): block \(i) span exceeds storage length"
                )
            }
        }
    }
    
    /// Splice range must always be valid (within old storage bounds)
    func testSpliceRangesAreAlwaysValid() throws {
        let doc = Document(blocks: [
            .paragraph(inline: [.text("First paragraph")]),
            .paragraph(inline: [.text("Second paragraph")])
        ], trailingNewline: false)
        let projection = DocumentProjection(document: doc, bodyFont: testFont(), codeFont: testFont())
        
        // Test various edit positions
        for offset in [0, 5, 15, 16, 20] {
            do {
                let result = try EditingOps.insert("X", at: min(offset, projection.attributed.length), in: projection)
                
                XCTAssertTrue(
                    result.spliceRange.location >= 0,
                    "Splice at offset \(offset) has negative location"
                )
                XCTAssertTrue(
                    result.spliceRange.location + result.spliceRange.length <= projection.attributed.length,
                    "Splice at offset \(offset) exceeds old storage length"
                )
            } catch EditingError.notInsideBlock {
                // Expected for offsets past the end
            } catch {
                // Other errors are fine for this test
            }
        }
    }
    
    // MARK: - Empty Heading Rendering Tests
    
    /// Empty heading (suffix is just the required " " separator) renders
    /// to zero characters — HeadingRenderer strips the single leading
    /// space — but position 0 still maps into the block so the first
    /// keystroke routes through insertIntoBlock(.heading)'s empty-heading
    /// branch and populates the suffix.
    func testEmptyHeadingRendersCorrectly() throws {
        let doc = Document(blocks: [.heading(level: 1, suffix: " ")], trailingNewline: false)
        let projection = DocumentProjection(document: doc, bodyFont: testFont(), codeFont: testFont())

        XCTAssertEqual(
            projection.attributed.length, 0,
            "Empty heading with suffix \" \" must render to zero chars (leading separator stripped)"
        )

        // Insert at position 0: routes through the empty-heading branch
        // which places the inserted text after the leading separator.
        let result = try EditingOps.insert("Title", at: 0, in: projection)
        XCTAssertTrue(
            result.newProjection.attributed.string.contains("Title"),
            "Inserted text should appear in rendered output"
        )
        // The serialized markdown must be a valid CommonMark heading.
        let md = MarkdownSerializer.serialize(result.newProjection.document)
        XCTAssertEqual(md, "# Title")
    }

    /// Empty heading accepts inserts at offset 0 (mapped to inside the
    /// block) but rejects offsets past the rendered end.
    func testEmptyHeadingInsertionAtVariousOffsets() throws {
        let doc = Document(blocks: [.heading(level: 1, suffix: " ")], trailingNewline: false)
        let projection = DocumentProjection(document: doc, bodyFont: testFont(), codeFont: testFont())

        // Offset 0 must succeed.
        let result = try EditingOps.insert("X", at: 0, in: projection)
        XCTAssertEqual(
            result.newProjection.attributed.length,
            projection.attributed.length + 1,
            "Insertion at offset 0 should increase length by 1"
        )
        XCTAssertTrue(result.spliceRange.location >= 0)
        XCTAssertTrue(
            result.spliceRange.location + result.spliceRange.length <= projection.attributed.length
        )

        // Offset 1 is past the rendered length of an empty heading and
        // must throw notInsideBlock — blockContaining returns nil.
        XCTAssertThrowsError(try EditingOps.insert("X", at: 1, in: projection))
    }
    
    // MARK: - Rendered Text Accuracy Tests
    
    /// Paragraph renders plain text correctly
    func testParagraphRenderedText() throws {
        let doc = Document(blocks: [.paragraph(inline: [.text("Hello World")])], trailingNewline: false)
        let projection = DocumentProjection(document: doc, bodyFont: testFont(), codeFont: testFont())
        
        XCTAssertEqual(
            projection.attributed.string,
            "Hello World",
            "Paragraph should render to its text content"
        )
    }
    
    /// Heading renders suffix text correctly (not the # markers)
    func testHeadingRenderedText() throws {
        let doc = Document(blocks: [.heading(level: 1, suffix: " Title")], trailingNewline: false)
        let projection = DocumentProjection(document: doc, bodyFont: testFont(), codeFont: testFont())
        
        // Should render "Title" (trimmed from suffix), not "# Title"
        let rendered = projection.attributed.string
        XCTAssertTrue(
            rendered.contains("Title"),
            "Heading should render its title text"
        )
        XCTAssertFalse(
            rendered.contains("#"),
            "Heading should not render # markers in output"
        )
    }
    
    /// List renders without markers in plain text (markers are attachments)
    func testListRenderedStructure() throws {
        let items = [
            ListItem(indent: "", marker: "-", afterMarker: " ", checkbox: nil, inline: [.text("Item 1")], children: []),
            ListItem(indent: "", marker: "-", afterMarker: " ", checkbox: nil, inline: [.text("Item 2")], children: [])
        ]
        let doc = Document(blocks: [.list(items: items)], trailingNewline: false)
        let projection = DocumentProjection(document: doc, bodyFont: testFont(), codeFont: testFont())
        
        // Should have text content
        let rendered = projection.attributed.string
        XCTAssertTrue(rendered.contains("Item 1"), "List should render item text")
        XCTAssertTrue(rendered.contains("Item 2"), "List should render item text")
        
        // Block spans should account for each item
        XCTAssertEqual(
            projection.blockSpans.count,
            1,
            "List is one block"
        )
    }
    
    /// Block spans must sum to total length (with separators)
    func testBlockSpansSumToTotalLength() throws {
        let doc = Document(blocks: [
            .paragraph(inline: [.text("First")]),
            .paragraph(inline: [.text("Second")]),
            .paragraph(inline: [.text("Third")])
        ], trailingNewline: false)
        let projection = DocumentProjection(document: doc, bodyFont: testFont(), codeFont: testFont())
        
        var totalSpanLength = 0
        var previousEnd = 0
        
        for (i, span) in projection.blockSpans.enumerated() {
            // Spans should be contiguous (with \n separators)
            if i > 0 {
                XCTAssertEqual(
                    span.location,
                    previousEnd + 1,
                    "Block \(i) should start after previous block's separator"
                )
            }
            totalSpanLength += span.length
            previousEnd = span.location + span.length
        }
        
        // Total length including separators between blocks
        let expectedLength = projection.attributed.length
        XCTAssertEqual(
            previousEnd,
            expectedLength,
            "Block spans should cover entire document"
        )
    }
    
    // MARK: - Edit Sequence Consistency Tests
    
    /// Multiple edits maintain consistency
    func testMultipleEditsMaintainConsistency() throws {
        var doc = Document(blocks: [.paragraph(inline: [.text("Start")])], trailingNewline: false)
        var projection = DocumentProjection(document: doc, bodyFont: testFont(), codeFont: testFont())
        
        let edits = ["H", "e", "l", "l", "o", " ", "W", "o", "r", "l", "d"]
        
        for (i, char) in edits.enumerated() {
            let result = try EditingOps.insert(char, at: projection.attributed.length, in: projection)
            
            // Verify consistency after each edit
            XCTAssertEqual(
                result.newProjection.attributed.length,
                projection.attributed.length + 1,
                "Edit \(i) ('\(char)'): length should increase by 1"
            )
            
            // Update for next iteration
            projection = result.newProjection
        }
        
        // Final text should be "StartHello World"
        XCTAssertEqual(
            projection.attributed.string,
            "StartHello World",
            "Final rendered text should match all insertions"
        )
    }
    
    /// Delete operations maintain consistency
    func testDeleteOperationsMaintainConsistency() throws {
        let doc = Document(blocks: [.paragraph(inline: [.text("Hello World")])], trailingNewline: false)
        let projection = DocumentProjection(document: doc, bodyFont: testFont(), codeFont: testFont())
        
        // Delete "World" (positions 6-10)
        let result = try EditingOps.delete(range: NSRange(location: 6, length: 5), in: projection)
        
        XCTAssertEqual(
            result.newProjection.attributed.string,
            "Hello ",
            "Delete should remove 'World'"
        )
        
        XCTAssertEqual(
            result.newProjection.attributed.length,
            projection.attributed.length - 5,
            "Length should decrease by deleted amount"
        )
    }
    
    // MARK: - Edge Case Tests
    
    /// Single character document
    func testSingleCharacterDocument() throws {
        let doc = Document(blocks: [.paragraph(inline: [.text("X")])], trailingNewline: false)
        let projection = DocumentProjection(document: doc, bodyFont: testFont(), codeFont: testFont())
        
        XCTAssertEqual(projection.attributed.length, 1)
        XCTAssertEqual(projection.blockSpans.count, 1)
        XCTAssertEqual(projection.blockSpans[0].length, 1)
    }
    
    /// Empty paragraph renders to zero characters. Position 0 still
    /// maps into the block (a zero-length span starting at 0 includes
    /// index 0) so the first insert routes into insertIntoBlock.
    func testEmptyParagraphRendering() throws {
        let doc = Document(blocks: [.paragraph(inline: [])], trailingNewline: false)
        let projection = DocumentProjection(document: doc, bodyFont: testFont(), codeFont: testFont())

        XCTAssertEqual(projection.attributed.length, 0)

        let result = try EditingOps.insert("Text", at: 0, in: projection)
        XCTAssertTrue(result.newProjection.attributed.string.contains("Text"))
    }
    
    // MARK: - Line-height stability (the "H1 + Enter + type shifts content by 1-2px" bug)

    /// Regression: pressing Return at the end of an H1 inserts an empty paragraph.
    /// Typing the first character into that paragraph must NOT shift the y-origin
    /// of subsequent paragraphs. Any such shift is a line-height mismatch between
    /// the empty-paragraph and the 1-character paragraph rendering.
    ///
    /// Pure-function test: runs DocumentRenderer -> NSTextStorage -> LayoutManager
    /// -> lineFragmentRect. No NSWindow, no EditTextView, no RunLoop.
    func testEmptyParagraphVsOneCharParagraphPreservesLayoutYOrigin() throws {
        let body = testFont()

        // State A: immediately after "Enter at end of H1".
        let docA = Document(blocks: [
            .heading(level: 1, suffix: "Title"),
            .paragraph(inline: []),
            .paragraph(inline: [.text("abc")]),
            .paragraph(inline: [.text("def")])
        ], trailingNewline: false)

        // State B: after typing a single character into the new empty paragraph.
        let docB = Document(blocks: [
            .heading(level: 1, suffix: "Title"),
            .paragraph(inline: [.text("x")]),
            .paragraph(inline: [.text("abc")]),
            .paragraph(inline: [.text("def")])
        ], trailingNewline: false)

        let yAbc_A = measureLineOriginY(for: docA, blockIndex: 2, bodyFont: body)
        let yAbc_B = measureLineOriginY(for: docB, blockIndex: 2, bodyFont: body)
        let yDef_A = measureLineOriginY(for: docA, blockIndex: 3, bodyFont: body)
        let yDef_B = measureLineOriginY(for: docB, blockIndex: 3, bodyFont: body)

        XCTAssertEqual(yAbc_A, yAbc_B, accuracy: 0.5,
            "'abc' shifted \(yAbc_B - yAbc_A)pt when paragraph([]) became paragraph([\"x\"]). " +
            "This is the classic H1+Enter+type visual shift bug.")
        XCTAssertEqual(yDef_A, yDef_B, accuracy: 0.5,
            "'def' shifted \(yDef_B - yDef_A)pt when paragraph([]) became paragraph([\"x\"]).")
    }

    /// Extend coverage to multi-line follow-on content, ensuring the shift doesn't
    /// compound deeper in the document.
    func testMultipleParagraphsBelowStayStableAcrossEmptyToOneChar() throws {
        let body = testFont()
        var blocksA: [Block] = [.heading(level: 1, suffix: "Title"), .paragraph(inline: [])]
        var blocksB: [Block] = [.heading(level: 1, suffix: "Title"), .paragraph(inline: [.text("x")])]
        for i in 0..<6 {
            blocksA.append(.paragraph(inline: [.text("line \(i)")]))
            blocksB.append(.paragraph(inline: [.text("line \(i)")]))
        }
        let docA = Document(blocks: blocksA, trailingNewline: false)
        let docB = Document(blocks: blocksB, trailingNewline: false)
        for i in 2..<blocksA.count {
            let yA = measureLineOriginY(for: docA, blockIndex: i, bodyFont: body)
            let yB = measureLineOriginY(for: docB, blockIndex: i, bodyFont: body)
            XCTAssertEqual(yA, yB, accuracy: 0.5,
                "block \(i) shifted \(yB - yA)pt across empty->1-char transition")
        }
    }

    /// The same scenario, but this time we MUTATE storage in place (the real
    /// editing path) instead of swapping in a fresh render. The live bug lives
    /// here: after Enter-on-H1, typing the first character must not shift the
    /// y-origin of blocks below the cursor. If fresh-render parity is fine but
    /// incremental-edit parity fails, the bug is in the splice / attribute
    /// re-sync / invalidation path, not the renderer.
    func testIncrementalEditAfterH1EnterPreservesLayoutYOrigin() throws {
        let body = testFont()

        let docA = Document(blocks: [
            .heading(level: 1, suffix: "Title"),
            .paragraph(inline: []),
            .paragraph(inline: [.text("abc")]),
            .paragraph(inline: [.text("def")])
        ], trailingNewline: false)
        let projectionA = DocumentProjection(document: docA, bodyFont: body, codeFont: body)

        let container = NSTextContainer(size: NSSize(width: 600, height: 10_000))
        container.lineFragmentPadding = 0
        // Phase 4.5: TK1 `LayoutManager` subclass deleted. Use base
        // `NSLayoutManager` — the subclass's line-height delegate logic
        // isn't exercised here; the test measures y-origin preservation
        // across edits, which only needs standard glyph math.
        let lm = NSLayoutManager()
        lm.addTextContainer(container)
        let storage = NSTextStorage(attributedString: projectionA.attributed)
        storage.addLayoutManager(lm)
        lm.ensureLayout(for: container)

        let yAbcBefore = lineOriginY(for: projectionA.blockSpans[2].location, in: lm, storage: storage)
        let yDefBefore = lineOriginY(for: projectionA.blockSpans[3].location, in: lm, storage: storage)

        // Simulate typing "x" into the empty paragraph at block 1.
        let insertAt = projectionA.blockSpans[1].location
        let result = try EditingOps.insert("x", at: insertAt, in: projectionA)

        // Apply splice the way EditTextView+BlockModel.applyEditResultWithUndo does:
        // replaceCharacters, then re-sync paragraphStyle from new projection.
        storage.beginEditing()
        storage.replaceCharacters(in: result.spliceRange, with: result.spliceReplacement)
        storage.endEditing()

        let newAttr = result.newProjection.attributed
        if newAttr.length == storage.length {
            let full = NSRange(location: 0, length: newAttr.length)
            newAttr.enumerateAttribute(.paragraphStyle, in: full, options: []) { value, range, _ in
                guard let newStyle = value as? NSParagraphStyle else { return }
                storage.addAttribute(.paragraphStyle, value: newStyle, range: range)
            }
        }
        lm.ensureLayout(for: container)

        let yAbcAfter = lineOriginY(for: result.newProjection.blockSpans[2].location, in: lm, storage: storage)
        let yDefAfter = lineOriginY(for: result.newProjection.blockSpans[3].location, in: lm, storage: storage)

        XCTAssertEqual(yAbcBefore, yAbcAfter, accuracy: 0.5,
            "incremental edit: 'abc' shifted \(yAbcAfter - yAbcBefore)pt after typing 'x' into new empty paragraph")
        XCTAssertEqual(yDefBefore, yDefAfter, accuracy: 0.5,
            "incremental edit: 'def' shifted \(yDefAfter - yDefBefore)pt after typing 'x' into new empty paragraph")
    }

    /// End-to-end reproducer: drive a real EditTextView + window + LayoutManager
    /// through the exact keystrokes that trigger the reported bug. Fails if
    /// lines below the insertion point shift by more than 0.5pt between "empty
    /// paragraph just created" and "one character typed into it".
    func testLiveEditorH1EnterThenTypeDoesNotShiftContentBelow() throws {
        let editor = makeBlockModelEditor()
        defer { tearDownBlockModelEditor(editor) }

        // Build initial state: H1 title + two paragraphs below.
        let startDoc = Document(blocks: [
            .heading(level: 1, suffix: "Title"),
            .paragraph(inline: [.text("abc")]),
            .paragraph(inline: [.text("def")])
        ], trailingNewline: false)
        loadDocument(startDoc, into: editor)

        // Sanity: before Enter, record y of "abc" and "def".
        let projection0 = editor.documentProjection!
        let yAbc_initial = measureY(for: projection0.blockSpans[1].location, in: editor)
        let yDef_initial = measureY(for: projection0.blockSpans[2].location, in: editor)

        // Move cursor to end of "Title" (end of block 0).
        let endOfH1 = NSMaxRange(projection0.blockSpans[0])
        editor.setSelectedRange(NSRange(location: endOfH1, length: 0))

        // Press Enter — this goes through the same path as real key events.
        let enterOK = editor.shouldChangeText(in: NSRange(location: endOfH1, length: 0), replacementString: "\n")
        XCTAssertFalse(enterOK, "block-model should intercept Enter and return false")
        editor.layoutManager!.ensureLayout(for: editor.textContainer!)

        let projection1 = editor.documentProjection!
        XCTAssertEqual(projection1.document.blocks.count, 4, "after Enter: [H1, paragraph([]), abc, def]")

        let yAbc_afterEnter = measureY(for: projection1.blockSpans[2].location, in: editor)
        let yDef_afterEnter = measureY(for: projection1.blockSpans[3].location, in: editor)

        dumpLineFragments(label: "AFTER-ENTER", editor: editor)

        // Type 'x' into the newly-created empty paragraph.
        let cursor = editor.selectedRange().location
        let typeOK = editor.shouldChangeText(in: NSRange(location: cursor, length: 0), replacementString: "x")
        XCTAssertFalse(typeOK, "block-model should intercept typing and return false")
        editor.layoutManager!.ensureLayout(for: editor.textContainer!)

        let projection2 = editor.documentProjection!
        let yAbc_afterType = measureY(for: projection2.blockSpans[2].location, in: editor)
        let yDef_afterType = measureY(for: projection2.blockSpans[3].location, in: editor)

        dumpLineFragments(label: "AFTER-TYPE", editor: editor)

        // The reported bug: content below shifts by 1-2pt when the first char
        // is typed into the blank paragraph. Before-typing y should equal
        // after-typing y (the blank paragraph line height must match the
        // one-character paragraph line height).
        XCTAssertEqual(yAbc_afterEnter, yAbc_afterType, accuracy: 0.5,
            "BUG: 'abc' shifted \(yAbc_afterType - yAbc_afterEnter)pt when typing first char into blank paragraph")
        XCTAssertEqual(yDef_afterEnter, yDef_afterType, accuracy: 0.5,
            "BUG: 'def' shifted \(yDef_afterType - yDef_afterEnter)pt when typing first char into blank paragraph")
        _ = (yAbc_initial, yDef_initial)  // silence unused warnings
    }

    private func dumpLineFragments(label: String, editor: EditTextView) {
        guard let lm = editor.layoutManager, let storage = editor.textStorage else { return }
        let nLines = lm.numberOfGlyphs
        print("---- \(label): storage.length=\(storage.length) string=\(storage.string.debugDescription) ----")
        var glyph = 0
        var lineNo = 0
        while glyph < nLines {
            var effGlyphRange = NSRange(location: 0, length: 0)
            let rect = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &effGlyphRange)
            let charRange = lm.characterRange(forGlyphRange: effGlyphRange, actualGlyphRange: nil)
            let snippet = (charRange.length > 0 && charRange.location < storage.length)
                ? (storage.string as NSString).substring(with: NSRange(location: charRange.location, length: min(charRange.length, storage.length - charRange.location))).debugDescription
                : "\"\""
            let font = charRange.length > 0
                ? (storage.attribute(.font, at: charRange.location, effectiveRange: nil) as? NSFont)
                : nil
            let ps = charRange.length > 0
                ? (storage.attribute(.paragraphStyle, at: charRange.location, effectiveRange: nil) as? NSParagraphStyle)
                : nil
            print("  line \(lineNo): glyphs=\(effGlyphRange) chars=\(charRange) rect.y=\(rect.origin.y) h=\(rect.size.height) text=\(snippet) font=\(font?.pointSize ?? -1) pSpacing=\(ps?.paragraphSpacing ?? -1) pBefore=\(ps?.paragraphSpacingBefore ?? -1) lineSpacing=\(ps?.lineSpacing ?? -1) minLH=\(ps?.minimumLineHeight ?? -1)")
            glyph = NSMaxRange(effGlyphRange)
            lineNo += 1
            if lineNo > 20 { break }
        }
    }

    // MARK: Full-pipeline editor helpers (with NSWindow, matching HeaderTests pattern)

    private func makeBlockModelEditor() -> EditTextView {
        let frame = NSRect(x: 0, y: 0, width: 600, height: 800)
        let container = NSTextContainer(size: frame.size)
        // Phase 4.5: TK1 `LayoutManager` subclass deleted. Use base
        // `NSLayoutManager` — the block-model path doesn't rely on the
        // subclass's drawing helpers (they live in TK2 fragments now).
        let layoutManager = NSLayoutManager()
        layoutManager.addTextContainer(container)
        let storage = NSTextStorage()
        storage.addLayoutManager(layoutManager)
        let editor = EditTextView(frame: frame, textContainer: container)
        editor.initTextStorage()
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView?.addSubview(editor)
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("H1ShiftTest_\(UUID().uuidString).md")
        try? "placeholder".write(to: tmp, atomically: true, encoding: .utf8)
        let project = Project(storage: Storage.shared(), url: tmp.deletingLastPathComponent())
        let note = Note(url: tmp, with: project)
        editor.note = note
        return editor
    }

    private func tearDownBlockModelEditor(_ editor: EditTextView) {
        if let url = editor.note?.url { try? FileManager.default.removeItem(at: url) }
    }

    private func loadDocument(_ doc: Document, into editor: EditTextView) {
        // Mirror the real fillViaBlockModel path: use the configured note
        // font (single source of truth) and gate the setAttributedString
        // with isRendering so the source-mode pipeline doesn't re-process
        // the rendered attributes.
        let projection = DocumentProjection(
            document: doc,
            bodyFont: UserDefaultsManagement.noteFont,
            codeFont: UserDefaultsManagement.codeFont
        )
        editor.textStorageProcessor?.isRendering = true
        editor.textStorage?.setAttributedString(projection.attributed)
        editor.textStorageProcessor?.isRendering = false
        editor.documentProjection = projection
        editor.textStorageProcessor?.blockModelActive = true
        // Phase 4.6: setter auto-syncs `processor.blocks`.
        editor.layoutManager!.ensureLayout(for: editor.textContainer!)
    }

    private func measureY(for charIndex: Int, in editor: EditTextView) -> CGFloat {
        let lm = editor.layoutManager!
        let storageLen = editor.textStorage!.length
        let idx = min(charIndex, max(0, storageLen - 1))
        let glyph = lm.glyphIndexForCharacter(at: idx)
        return lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).origin.y
    }

    private func lineOriginY(for charIndex: Int, in lm: NSLayoutManager, storage: NSTextStorage) -> CGFloat {
        let idx = min(charIndex, max(0, storage.length - 1))
        let glyph = lm.glyphIndexForCharacter(at: idx)
        return lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).origin.y
    }

    /// Layout a document and return the y-origin of the line fragment that starts
    /// at the given block's first character.
    ///
    /// Phase 4.5: previously used the custom `LayoutManager` subclass so
    /// its font/line-height delegate logic was exercised; that subclass
    /// is gone, so this helper now measures against a base
    /// `NSLayoutManager`. The test remains meaningful because the
    /// renderer-set `.paragraphStyle` (minLineHeight / paragraphSpacing)
    /// still drives line metrics through standard AppKit paths.
    private func measureLineOriginY(
        for document: Document,
        blockIndex: Int,
        bodyFont: NSFont
    ) -> CGFloat {
        let rendered = DocumentRenderer.render(document, bodyFont: bodyFont, codeFont: bodyFont)
        let container = NSTextContainer(size: NSSize(width: 600, height: 10_000))
        container.lineFragmentPadding = 0
        let lm = NSLayoutManager()
        lm.addTextContainer(container)
        let storage = NSTextStorage(attributedString: rendered.attributed)
        storage.addLayoutManager(lm)
        lm.ensureLayout(for: container)

        let span = rendered.blockSpans[blockIndex]
        // For empty blocks (length 0), the block's "line" is whatever line fragment
        // covers that insertion point. For non-empty blocks, use the span's start.
        let charIndex = min(span.location, max(0, storage.length - 1))
        let glyph = lm.glyphIndexForCharacter(at: charIndex)
        let rect = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        return rect.origin.y
    }

    private func testFont() -> NSFont {
        return NSFont.systemFont(ofSize: 14)
    }
}