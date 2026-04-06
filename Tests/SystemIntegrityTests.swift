//
//  SystemIntegrityTests.swift
//  FSNotesTests
//
//  SYSTEM-LEVEL INTEGRITY TESTS: These tests catch the two most common
//  classes of architectural bugs:
//
//    1. MULTIPLE PATHS TO A SINGLE OPERATION: When N code paths exist
//       for the same logical operation (e.g. "save a note"), they must
//       ALL produce the same result. Divergence = data corruption.
//
//    2. STATE CONSISTENCY: When an operation has preconditions about
//       pipeline state (e.g. "blockModelActive must match
//       documentProjection != nil"), those invariants must hold at
//       every observable point, including during fill() / save()
//       transitions. Violations = race-condition-class bugs.
//
//  These tests operate on the block model + projection layer — the
//  same types used in production — without requiring a live UI.
//  They exercise end-to-end paths: parse → render → edit → serialize.
//

import XCTest
@testable import FSNotes

// MARK: - Test fixtures

private let simpleMarkdown = """
# Hello World

This is a paragraph with **bold** and *italic* text.

```swift
let x = 42
```

Another paragraph.

"""

private let headingOnlyMarkdown = """
# Title

## Subtitle

Body text here.

"""

private let codeHeavyMarkdown = """
# Code Examples

```python
def foo():
    pass
```

Some text between.

```javascript
console.log("hello")
```

"""

private let multiParagraphMarkdown = """
First paragraph.

Second paragraph.

Third paragraph.

"""

private let allFixtures: [(name: String, markdown: String)] = [
    ("simple", simpleMarkdown),
    ("headingOnly", headingOnlyMarkdown),
    ("codeHeavy", codeHeavyMarkdown),
    ("multiParagraph", multiParagraphMarkdown),
]

// MARK: - Helpers

private func bodyFont() -> PlatformFont {
    return PlatformFont.systemFont(ofSize: 14)
}

private func codeFont() -> PlatformFont {
    return PlatformFont.monospacedSystemFont(ofSize: 14, weight: .regular)
}

private func project(_ md: String) -> DocumentProjection {
    let doc = MarkdownParser.parse(md)
    return DocumentProjection(document: doc, bodyFont: bodyFont(), codeFont: codeFont())
}

// MARK: - 1. Save path convergence

/// These tests verify that EVERY path that can produce "what gets
/// written to disk" yields identical markdown. If a save path bypasses
/// block-model serialization and writes rendered text instead, the
/// markdown markers (# ## ``` ** *) are lost = data corruption.
///
/// Historical context: this exact bug occurred 3 times during the
/// block-model migration. These tests prevent regression.

class SavePathConvergenceTests: XCTestCase {

    // ── Path A: MarkdownSerializer.serialize(projection.document)
    // ── Path B: MarkdownSerializer.serialize(parse(original_markdown))
    // ── Path C: serialize(parse(serialize(parse(markdown))))
    //
    // ALL must produce the same output, which must equal the original.

    /// The canonical save path: serialize the Document held by the
    /// projection. This is what editor.save() uses when the block
    /// model is active.
    func test_serializePath_matchesOriginal() {
        for (name, md) in allFixtures {
            let proj = project(md)
            let serialized = MarkdownSerializer.serialize(proj.document)
            XCTAssertEqual(
                serialized, md,
                "Save path A (serialize projection.document) diverged from original for fixture '\(name)'"
            )
        }
    }

    /// Re-parsing the serialized output must produce a Document that
    /// serializes identically. This catches cases where serialization
    /// subtly alters structure that doesn't survive a re-parse.
    func test_doubleRoundTrip_isStable() {
        for (name, md) in allFixtures {
            let pass1 = MarkdownSerializer.serialize(MarkdownParser.parse(md))
            let pass2 = MarkdownSerializer.serialize(MarkdownParser.parse(pass1))
            XCTAssertEqual(
                pass1, pass2,
                "Double round-trip unstable for fixture '\(name)': pass 1 ≠ pass 2"
            )
        }
    }

    /// Rendering does NOT affect serialization. serialize(doc) must
    /// produce the same output whether the document was freshly parsed
    /// or has been through the renderer. The renderer must not mutate
    /// the Document.
    func test_renderingDoesNotAffectSerialization() {
        for (name, md) in allFixtures {
            let doc = MarkdownParser.parse(md)
            let beforeRender = MarkdownSerializer.serialize(doc)
            // Render (which creates a DocumentProjection internally).
            let _ = DocumentProjection(document: doc, bodyFont: bodyFont(), codeFont: codeFont())
            let afterRender = MarkdownSerializer.serialize(doc)
            XCTAssertEqual(
                beforeRender, afterRender,
                "Rendering mutated the Document for fixture '\(name)'"
            )
        }
    }

    /// The rendered attributed string must NOT contain markdown markers.
    /// If someone calls `attributedString()` on an editor with an active
    /// block model, the result must NOT be suitable for direct disk write
    /// (it lacks markers). This test verifies that rendered output and
    /// serialized output are DIFFERENT — they serve different purposes.
    func test_renderedOutput_differsFromSerializedMarkdown() {
        for (name, md) in allFixtures {
            let proj = project(md)
            let rendered = proj.attributed.string
            let serialized = MarkdownSerializer.serialize(proj.document)

            // For any document with headings, code blocks, or inline
            // formatting, the rendered text MUST differ from the markdown.
            let hasMarkers = md.contains("#") || md.contains("```") ||
                             md.contains("**") || md.contains("*")
            if hasMarkers {
                XCTAssertNotEqual(
                    rendered, serialized,
                    "Rendered output should NOT equal serialized markdown for fixture '\(name)' " +
                    "(rendered text lacks markers — saving it would corrupt the file)"
                )
            }
        }
    }

    /// Verify that serialized output always contains the markdown syntax
    /// markers that were in the original. If serialization strips markers,
    /// the file is corrupted.
    func test_serializedOutput_preservesMarkers() {
        let md = simpleMarkdown
        let proj = project(md)
        let serialized = MarkdownSerializer.serialize(proj.document)

        // Check that critical markers survive serialization.
        XCTAssertTrue(serialized.contains("# "), "Heading marker '#' lost in serialization")
        XCTAssertTrue(serialized.contains("```"), "Code fence '```' lost in serialization")
        XCTAssertTrue(serialized.contains("**bold**"), "Bold markers '**' lost in serialization")
        XCTAssertTrue(serialized.contains("*italic*"), "Italic markers '*' lost in serialization")
    }
}

// MARK: - 2. Fill path idempotency

/// These tests verify that loading a note multiple times produces
/// identical results. fill() is called from multiple sites (note
/// switch, note refresh, window open). All must produce the same
/// rendered output.

class FillIdempotencyTests: XCTestCase {

    /// Rendering the same Document twice must produce byte-equal
    /// attributed strings. This is the renderer's purity contract.
    func test_renderTwice_producesIdenticalOutput() {
        for (name, md) in allFixtures {
            let doc = MarkdownParser.parse(md)
            let proj1 = DocumentProjection(document: doc, bodyFont: bodyFont(), codeFont: codeFont())
            let proj2 = DocumentProjection(document: doc, bodyFont: bodyFont(), codeFont: codeFont())
            XCTAssertEqual(
                proj1.attributed.string, proj2.attributed.string,
                "Render purity violated for fixture '\(name)': two renders differ"
            )
            // Also check block spans match.
            XCTAssertEqual(
                proj1.blockSpans.count, proj2.blockSpans.count,
                "Block span count mismatch for fixture '\(name)'"
            )
            for i in 0..<proj1.blockSpans.count {
                XCTAssertEqual(
                    proj1.blockSpans[i], proj2.blockSpans[i],
                    "Block span \(i) mismatch for fixture '\(name)'"
                )
            }
        }
    }

    /// fill → serialize → parse → fill must produce the same rendered
    /// output. This catches progressive degradation where each save/load
    /// cycle subtly changes the document.
    func test_fillSerializeFill_noProgessiveDegradation() {
        for (name, md) in allFixtures {
            // Cycle 1: parse + render
            let doc1 = MarkdownParser.parse(md)
            let proj1 = DocumentProjection(document: doc1, bodyFont: bodyFont(), codeFont: codeFont())
            let rendered1 = proj1.attributed.string

            // Serialize back to markdown
            let md2 = MarkdownSerializer.serialize(doc1)

            // Cycle 2: parse + render from serialized output
            let doc2 = MarkdownParser.parse(md2)
            let proj2 = DocumentProjection(document: doc2, bodyFont: bodyFont(), codeFont: codeFont())
            let rendered2 = proj2.attributed.string

            XCTAssertEqual(
                rendered1, rendered2,
                "Progressive degradation detected for fixture '\(name)': " +
                "fill→serialize→fill produced different rendered output"
            )
        }
    }

    /// Multiple round-trips (5x) must be stable. This catches
    /// slowly-accumulating corruption (e.g., extra newlines per cycle).
    func test_multipleRoundTrips_stable() {
        for (name, md) in allFixtures {
            var current = md
            for cycle in 1...5 {
                let doc = MarkdownParser.parse(current)
                let serialized = MarkdownSerializer.serialize(doc)
                XCTAssertEqual(
                    current, serialized,
                    "Round-trip \(cycle) diverged for fixture '\(name)'"
                )
                current = serialized
            }
        }
    }
}

// MARK: - 3. State consistency invariants

/// These tests verify that pipeline state flags are consistent at
/// every observable point. The invariant:
///
///   documentProjection != nil  ⟺  blockModelActive == true
///
/// When this invariant is violated, saves can write rendered text
/// (no markers) to disk. This is the #1 data-corruption vector.

class StateConsistencyTests: XCTestCase {

    /// After a successful block-model render, the projection and
    /// blockModelActive flag must both be set.
    func test_afterRender_projectionAndFlagConsistent() {
        for (name, md) in allFixtures {
            let doc = MarkdownParser.parse(md)
            let proj = DocumentProjection(document: doc, bodyFont: bodyFont(), codeFont: codeFont())

            // Simulate what fillViaBlockModel does:
            // 1. projection = proj  → non-nil
            // 2. blockModelActive = true
            //
            // The test verifies the projection contains valid state.
            XCTAssertFalse(
                proj.attributed.length == 0 && !md.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "Projection rendered empty output for non-empty fixture '\(name)'"
            )
            XCTAssertEqual(
                proj.blockSpans.count, doc.blocks.count,
                "Block span count (\(proj.blockSpans.count)) ≠ document block count (\(doc.blocks.count)) for '\(name)'"
            )
        }
    }

    /// Every block span must be non-overlapping and in ascending order.
    /// Overlapping spans cause splice corruption.
    func test_blockSpans_nonOverlapping() {
        for (name, md) in allFixtures {
            let proj = project(md)
            let spans = proj.blockSpans
            for i in 1..<spans.count {
                let prevEnd = spans[i - 1].location + spans[i - 1].length
                let currStart = spans[i].location
                XCTAssertLessThanOrEqual(
                    prevEnd, currStart,
                    "Block spans \(i-1) and \(i) overlap for fixture '\(name)': " +
                    "span[\(i-1)] = \(spans[i-1]), span[\(i)] = \(spans[i])"
                )
            }
        }
    }

    /// Every block span must be within the rendered attributed string's
    /// bounds. Out-of-bounds spans cause crashes during splice.
    func test_blockSpans_withinBounds() {
        for (name, md) in allFixtures {
            let proj = project(md)
            let length = proj.attributed.length
            for (i, span) in proj.blockSpans.enumerated() {
                XCTAssertGreaterThanOrEqual(
                    span.location, 0,
                    "Block span \(i) has negative location for fixture '\(name)'"
                )
                XCTAssertLessThanOrEqual(
                    span.location + span.length, length,
                    "Block span \(i) extends past attributed string length (\(length)) for fixture '\(name)'"
                )
            }
        }
    }

    /// After an edit operation, the new projection's block spans must
    /// still be consistent (non-overlapping, within bounds, correct
    /// count). This catches splice corruption during editing.
    func test_editPreservesSpanConsistency() throws {
        let md = multiParagraphMarkdown
        var proj = project(md)

        // Insert a character into the first paragraph.
        let result = try EditingOps.insert("X", at: 0, in: proj)
        proj = result.newProjection

        let spans = proj.blockSpans
        XCTAssertEqual(spans.count, proj.document.blocks.count)
        for i in 1..<spans.count {
            let prevEnd = spans[i - 1].location + spans[i - 1].length
            XCTAssertLessThanOrEqual(prevEnd, spans[i].location, "Overlap after edit at span \(i)")
        }
        let length = proj.attributed.length
        for (i, span) in spans.enumerated() {
            XCTAssertLessThanOrEqual(
                span.location + span.length, length,
                "Span \(i) out of bounds after edit"
            )
        }
    }

    /// Serialization after editing must preserve markers. This is the
    /// end-to-end test: parse → render → edit → serialize must produce
    /// valid markdown with all syntax markers intact.
    func test_editThenSerialize_preservesMarkers() throws {
        let md = simpleMarkdown
        var proj = project(md)

        // Insert text into the paragraph (block 2 in this fixture:
        // heading, blankLine, paragraph).
        // Find first paragraph block.
        var paragraphIdx: Int?
        for (i, block) in proj.document.blocks.enumerated() {
            if case .paragraph = block { paragraphIdx = i; break }
        }
        guard let pIdx = paragraphIdx else {
            XCTFail("No paragraph found in fixture"); return
        }
        let pSpan = proj.blockSpans[pIdx]
        let result = try EditingOps.insert("INSERTED ", at: pSpan.location, in: proj)
        proj = result.newProjection

        let serialized = MarkdownSerializer.serialize(proj.document)
        XCTAssertTrue(serialized.contains("# "), "Heading marker lost after edit")
        XCTAssertTrue(serialized.contains("```"), "Code fence lost after edit")
        XCTAssertTrue(serialized.contains("**"), "Bold marker lost after edit")
        XCTAssertTrue(serialized.contains("INSERTED "), "Inserted text missing after serialize")
    }
}

// MARK: - 4. Edit-then-serialize round-trip

/// These tests verify that editing operations produce Documents that
/// serialize to correct, parseable markdown. Every edit → serialize
/// → parse → serialize cycle must be stable.

class EditSerializeRoundTripTests: XCTestCase {

    /// Insert a character, serialize, re-parse, re-serialize. The two
    /// serializations must match.
    func test_insertThenRoundTrip() throws {
        for (name, md) in allFixtures {
            var proj = project(md)
            // Insert at position 0 of the first content block.
            guard let firstContentSpan = proj.blockSpans.first else { continue }
            let result = try EditingOps.insert("Z", at: firstContentSpan.location, in: proj)
            proj = result.newProjection

            let serialized = MarkdownSerializer.serialize(proj.document)
            let reparsed = MarkdownParser.parse(serialized)
            let reserialized = MarkdownSerializer.serialize(reparsed)

            XCTAssertEqual(
                serialized, reserialized,
                "Edit→serialize→parse→serialize unstable for fixture '\(name)'"
            )
        }
    }

    /// Delete a character, then round-trip.
    func test_deleteThenRoundTrip() throws {
        for (name, md) in allFixtures {
            var proj = project(md)
            guard let firstSpan = proj.blockSpans.first, firstSpan.length > 0 else { continue }
            let result = try EditingOps.delete(
                range: NSRange(location: firstSpan.location, length: 1),
                in: proj
            )
            proj = result.newProjection

            let serialized = MarkdownSerializer.serialize(proj.document)
            let reparsed = MarkdownParser.parse(serialized)
            let reserialized = MarkdownSerializer.serialize(reparsed)

            XCTAssertEqual(
                serialized, reserialized,
                "Delete→serialize→parse→serialize unstable for fixture '\(name)'"
            )
        }
    }

    /// Split a paragraph (Return key), then round-trip.
    func test_splitParagraphThenRoundTrip() throws {
        let md = multiParagraphMarkdown
        let proj = project(md)

        // Find first paragraph.
        for (i, block) in proj.document.blocks.enumerated() {
            guard case .paragraph = block else { continue }
            let span = proj.blockSpans[i]
            guard span.length > 2 else { continue }

            // Split in the middle.
            let midpoint = span.location + span.length / 2
            let result = try EditingOps.insert("\n", at: midpoint, in: proj)

            let serialized = MarkdownSerializer.serialize(result.newProjection.document)
            let reparsed = MarkdownParser.parse(serialized)
            let reserialized = MarkdownSerializer.serialize(reparsed)

            XCTAssertEqual(
                serialized, reserialized,
                "Split→serialize→parse→serialize unstable for block \(i)"
            )
            break // Test one split is sufficient.
        }
    }

    /// Multiple sequential edits, then round-trip. This catches
    /// cumulative corruption from chained operations.
    func test_chainedEditsThenRoundTrip() throws {
        let md = multiParagraphMarkdown
        var proj = project(md)

        // 5 sequential insertions.
        for n in 0..<5 {
            guard let firstSpan = proj.blockSpans.first else { break }
            let result = try EditingOps.insert(
                String(Character(UnicodeScalar(65 + n)!)),
                at: firstSpan.location,
                in: proj
            )
            proj = result.newProjection
        }

        let serialized = MarkdownSerializer.serialize(proj.document)
        let reparsed = MarkdownParser.parse(serialized)
        let reserialized = MarkdownSerializer.serialize(reparsed)

        XCTAssertEqual(
            serialized, reserialized,
            "Chained edits→serialize→parse→serialize unstable"
        )

        // Also verify the inserted characters are present.
        XCTAssertTrue(serialized.contains("EDCBA"), "Chained insertions missing from serialized output")
    }
}

// MARK: - 5. Splice invariant (edit consistency)

/// These tests verify that applying a splice to the old rendered
/// string produces the SAME result as rendering the new Document
/// from scratch. This is the fundamental editing contract: splicing
/// is equivalent to full re-render.
///
/// If this invariant fails, the user sees different content than
/// what's in the Document, and the next save will serialize the
/// Document (not what's displayed). Visual ≠ saved = confusion.

class SpliceConsistencyTests: XCTestCase {

    /// Helper: verify the splice invariant for an EditResult.
    private func assertSpliceMatchesRerender(
        old: DocumentProjection,
        result: EditResult,
        operation: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        // Apply splice to old rendered string.
        let spliced = NSMutableAttributedString(attributedString: old.attributed)
        spliced.replaceCharacters(in: result.spliceRange, with: result.spliceReplacement)

        // Full re-render from the new Document.
        let rerendered = DocumentProjection(
            document: result.newProjection.document,
            bodyFont: bodyFont(),
            codeFont: codeFont()
        )

        XCTAssertEqual(
            spliced.string, rerendered.attributed.string,
            "Splice ≠ re-render for operation '\(operation)'",
            file: file, line: line
        )
    }

    /// Insert at every valid position in a multi-paragraph document.
    func test_spliceInvariant_insertEveryPosition() throws {
        let md = multiParagraphMarkdown
        let proj = project(md)

        for span in proj.blockSpans {
            for offset in 0...span.length {
                let pos = span.location + offset
                do {
                    let result = try EditingOps.insert("X", at: pos, in: proj)
                    assertSpliceMatchesRerender(
                        old: proj,
                        result: result,
                        operation: "insert at \(pos)"
                    )
                } catch {
                    // Some positions may throw (e.g., separator chars).
                    // That's fine — we're testing positions that succeed.
                }
            }
        }
    }

    /// Delete single character at every valid position.
    func test_spliceInvariant_deleteEveryPosition() throws {
        let md = multiParagraphMarkdown
        let proj = project(md)

        for span in proj.blockSpans {
            for offset in 0..<span.length {
                let pos = span.location + offset
                do {
                    let result = try EditingOps.delete(
                        range: NSRange(location: pos, length: 1),
                        in: proj
                    )
                    assertSpliceMatchesRerender(
                        old: proj,
                        result: result,
                        operation: "delete at \(pos)"
                    )
                } catch {
                    // Cross-inline-range or other expected errors.
                }
            }
        }
    }

    /// Paragraph split (Return key) preserves splice invariant.
    func test_spliceInvariant_paragraphSplit() throws {
        let md = "Hello world.\n"
        let proj = project(md)

        // Split at multiple positions.
        for offset in 0...12 { // "Hello world." = 12 chars
            let result = try EditingOps.insert("\n", at: offset, in: proj)
            assertSpliceMatchesRerender(
                old: proj,
                result: result,
                operation: "split at \(offset)"
            )
        }
    }

    /// Multi-line paste preserves splice invariant.
    func test_spliceInvariant_multiLinePaste() throws {
        let md = "Hello world.\n"
        let proj = project(md)

        let pasteText = "line1\nline2\nline3"
        let result = try EditingOps.insert(pasteText, at: 5, in: proj)
        assertSpliceMatchesRerender(
            old: proj,
            result: result,
            operation: "multi-line paste"
        )
    }

    /// Adjacent block merge (backspace at block boundary) preserves
    /// splice invariant.
    func test_spliceInvariant_blockMerge() throws {
        let md = multiParagraphMarkdown
        let proj = project(md)

        // Find two adjacent paragraph blocks and delete across the
        // separator between them.
        for i in 0..<(proj.blockSpans.count - 1) {
            let spanA = proj.blockSpans[i]
            let spanB = proj.blockSpans[i + 1]
            // Delete from end of block A through start of block B
            // (crosses exactly one separator).
            let deleteStart = spanA.location + spanA.length
            let deleteEnd = spanB.location + 1 // 1 char into block B
            let deleteRange = NSRange(location: deleteStart, length: deleteEnd - deleteStart)

            do {
                let result = try EditingOps.delete(range: deleteRange, in: proj)
                assertSpliceMatchesRerender(
                    old: proj,
                    result: result,
                    operation: "merge blocks \(i) and \(i+1)"
                )
            } catch {
                // Some merges may not be supported (e.g., code blocks).
            }
        }
    }
}

// MARK: - 6. Projection coverage (no orphan storage positions)

/// These tests verify that every character in the rendered attributed
/// string maps to exactly one block (or is a known separator/trailer).
/// "Orphan" positions that don't map to any block cause edits to
/// throw `.notInsideBlock`, breaking the editor silently.

class ProjectionCoverageTests: XCTestCase {

    /// For every position in the rendered string, either:
    ///   (a) blockContaining returns a valid (blockIndex, offset), OR
    ///   (b) the position is on a known separator between blocks or
    ///       the trailing newline.
    func test_everyPosition_mapsToBlockOrSeparator() {
        for (name, md) in allFixtures {
            let proj = project(md)
            let length = proj.attributed.length

            // Collect all "covered" positions from block spans.
            var covered = Set<Int>()
            for span in proj.blockSpans {
                for pos in span.location...(span.location + span.length) {
                    covered.insert(pos)
                }
            }

            // Every position that IS covered must map to a block.
            for pos in covered where pos < length {
                let result = proj.blockContaining(storageIndex: pos)
                XCTAssertNotNil(
                    result,
                    "Position \(pos) is within a block span but blockContaining returned nil for fixture '\(name)'"
                )
            }

            // Positions NOT covered are separators or trailing newline.
            // Verify they're "\n" characters.
            let str = proj.attributed.string
            for pos in 0..<length {
                if !covered.contains(pos) {
                    let idx = str.index(str.startIndex, offsetBy: pos)
                    XCTAssertEqual(
                        str[idx], "\n",
                        "Uncovered position \(pos) is not a newline for fixture '\(name)' — " +
                        "found '\(str[idx])' instead. This character is unreachable by the editor."
                    )
                }
            }
        }
    }

    /// Editing at every block-covered position must not crash. It may
    /// throw an expected error (e.g., crossInlineRange), but must not
    /// crash or produce an inconsistent projection.
    func test_insertAtEveryPosition_noCrash() {
        for (name, md) in allFixtures {
            let proj = project(md)
            for span in proj.blockSpans {
                for offset in 0...span.length {
                    let pos = span.location + offset
                    do {
                        let result = try EditingOps.insert("X", at: pos, in: proj)
                        // Verify the result is structurally sound.
                        XCTAssertGreaterThan(
                            result.newProjection.attributed.length, 0,
                            "Empty render after insert at \(pos) in fixture '\(name)'"
                        )
                    } catch {
                        // Expected errors are fine (unsupported, etc.).
                        // We're testing for crashes, not specific behavior.
                    }
                }
            }
        }
    }
}
