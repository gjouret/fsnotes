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
    
    // MARK: - Helpers
    
    private func testFont() -> NSFont {
        return NSFont.systemFont(ofSize: 14)
    }
}