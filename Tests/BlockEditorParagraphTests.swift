//
//  BlockEditorParagraphTests.swift
//  FSNotesTests
//
//  Phase 12.B.1 — ParagraphBlockEditor unit tests.
//
//  Pure-function tests for the extracted paragraph editor. Because the
//  editor is stateless and operates only on `Block` values, these
//  tests don't need any AppKit / view setup — they exercise the editor
//  directly. The wider `EditingOperationsTests` and `EditContractTests`
//  suites continue to cover the integrated `EditingOps.insert` /
//  `delete` / `replace` paths with their full contract semantics; this
//  suite pins the per-kind editor's surface so a future structural
//  refactor (12.B.2 → 12.B.7) can rely on each editor in isolation.
//

import XCTest
@testable import FSNotes

final class BlockEditorParagraphTests: XCTestCase {

    // MARK: - insert

    func test_insert_intoEmptyParagraph_createsTextRun() throws {
        let block = Block.paragraph(inline: [])
        let result = try ParagraphBlockEditor.insert(into: block, offsetInBlock: 0, string: "hello")
        XCTAssertEqual(result, .paragraph(inline: [.text("hello")]))
    }

    func test_insert_intoEmptyParagraph_atNonZeroOffset_throws() {
        let block = Block.paragraph(inline: [])
        XCTAssertThrowsError(try ParagraphBlockEditor.insert(into: block, offsetInBlock: 1, string: "x"))
    }

    func test_insert_intoPlainText_atMid_extendsLeaf() throws {
        let block = Block.paragraph(inline: [.text("abcd")])
        let result = try ParagraphBlockEditor.insert(into: block, offsetInBlock: 2, string: "X")
        XCTAssertEqual(result, .paragraph(inline: [.text("abXcd")]))
    }

    func test_insert_atEndOfBoldRun_producesSibling() throws {
        // "**bold**" with cursor right after the closing run.
        // insertInlinesPreservingContainerContext should produce a
        // sibling text node, not extend the bold span. (Honouring the
        // fence semantic that end-of-formatting is a fence.)
        let block = Block.paragraph(inline: [.bold([.text("bold")])])
        let result = try ParagraphBlockEditor.insert(into: block, offsetInBlock: 4, string: "X")
        // Result should contain the bold run intact + a trailing .text("X").
        guard case .paragraph(let inline) = result else {
            return XCTFail("result is not a paragraph: \(result)")
        }
        XCTAssertEqual(inline.count, 2, "expected sibling .text after .bold; got \(inline)")
        if case .bold(let inner, _) = inline[0] {
            XCTAssertEqual(inner, [.text("bold")])
        } else {
            XCTFail("first inline is not .bold: \(inline[0])")
        }
        if case .text(let s) = inline[1] {
            XCTAssertEqual(s, "X")
        } else {
            XCTFail("second inline is not .text: \(inline[1])")
        }
    }

    func test_insert_intoParagraphWithImage_splicesAroundImage() throws {
        // [text "ab"][image][text "cd"] — insert at offset 3 (which is
        // between the image and "cd"). splitInlines should cut around
        // the image atom and insert the text after it.
        let block = Block.paragraph(inline: [
            .text("ab"),
            .image(alt: [.text("alt")], rawDestination: "u", width: nil),
            .text("cd")
        ])
        let result = try ParagraphBlockEditor.insert(into: block, offsetInBlock: 3, string: "X")
        guard case .paragraph(let inline) = result else {
            return XCTFail("result is not a paragraph: \(result)")
        }
        // Image must survive intact. Inserted "X" lands between image and "cd".
        var imageFound = false
        for item in inline {
            if case .image = item { imageFound = true }
        }
        XCTAssertTrue(imageFound, "image was lost: \(inline)")
        let raw = MarkdownSerializer.serializeInlines(inline)
        XCTAssertTrue(raw.contains("X"), "inserted X missing: \(raw)")
        XCTAssertTrue(raw.contains("ab"), "leading text missing: \(raw)")
        XCTAssertTrue(raw.contains("cd"), "trailing text missing: \(raw)")
    }

    func test_insert_onNonParagraphBlock_throws() {
        let block = Block.heading(level: 1, suffix: "h")
        XCTAssertThrowsError(try ParagraphBlockEditor.insert(into: block, offsetInBlock: 0, string: "x"))
    }

    // MARK: - delete

    func test_delete_zeroLength_returnsBlockUnchanged() throws {
        let block = Block.paragraph(inline: [.text("abcd")])
        let result = try ParagraphBlockEditor.delete(in: block, from: 2, to: 2)
        XCTAssertEqual(result, block)
    }

    func test_delete_withinPlainText_removesSubstring() throws {
        let block = Block.paragraph(inline: [.text("abcd")])
        let result = try ParagraphBlockEditor.delete(in: block, from: 1, to: 3)
        XCTAssertEqual(result, .paragraph(inline: [.text("ad")]))
    }

    func test_delete_acrossBoldBoundary_throwsCrossInlineRange() {
        // "abc**bold**xyz" — delete from offset 1 (in "abc") to offset
        // 5 (inside "bold"). Crosses a leaf boundary; delete must throw.
        let block = Block.paragraph(inline: [
            .text("abc"),
            .bold([.text("bold")]),
            .text("xyz")
        ])
        XCTAssertThrowsError(try ParagraphBlockEditor.delete(in: block, from: 1, to: 5)) { err in
            guard let e = err as? EditingError else { return XCTFail("not an EditingError: \(err)") }
            if case .crossInlineRange = e { /* expected */ }
            else { XCTFail("expected .crossInlineRange, got \(e)") }
        }
    }

    func test_delete_imageContainingParagraph_splicesAroundImage() throws {
        let block = Block.paragraph(inline: [
            .text("ab"),
            .image(alt: [.text("alt")], rawDestination: "u", width: nil),
            .text("cd")
        ])
        // Delete just the image (offset 2, which is the image's render position; len=1).
        let result = try ParagraphBlockEditor.delete(in: block, from: 2, to: 3)
        guard case .paragraph(let inline) = result else {
            return XCTFail("result is not a paragraph: \(result)")
        }
        for item in inline {
            if case .image = item { return XCTFail("image survived delete: \(inline)") }
        }
        let raw = MarkdownSerializer.serializeInlines(inline)
        XCTAssertEqual(raw, "abcd", "expected text fragments to merge after image deletion: got \(raw)")
    }

    func test_delete_onNonParagraphBlock_throws() {
        let block = Block.heading(level: 1, suffix: "h")
        XCTAssertThrowsError(try ParagraphBlockEditor.delete(in: block, from: 0, to: 1))
    }

    // MARK: - replace

    func test_replace_intoEmptyParagraph_createsTextRun() throws {
        let block = Block.paragraph(inline: [])
        let result = try ParagraphBlockEditor.replace(in: block, from: 0, to: 0, with: "hello")
        XCTAssertEqual(result, .paragraph(inline: [.text("hello")]))
    }

    func test_replace_withinSingleLeaf_splicesInPlace() throws {
        let block = Block.paragraph(inline: [.text("abcdef")])
        let result = try ParagraphBlockEditor.replace(in: block, from: 2, to: 4, with: "XY")
        XCTAssertEqual(result, .paragraph(inline: [.text("abXYef")]))
    }

    func test_replace_acrossInlineBoundary_splicesViaSplit() throws {
        // "abc**bold**xyz" — replace [1, 5) (crosses "abc" → into "bold").
        // The cross-leaf branch uses splitInlines + cleanInlines to fold
        // the replacement into the resulting paragraph. Critically, the
        // bold span around what survives ("ld") is preserved — only the
        // *characters* in [1,5) are replaced, not the formatting context
        // of the right-hand survivors. This is the contract documented
        // in the splitInlines + insertInlinesPreservingContainerContext
        // helpers and is what makes formatting survive a cross-format
        // user selection + paste / delete-and-retype.
        let block = Block.paragraph(inline: [
            .text("abc"),
            .bold([.text("bold")]),
            .text("xyz")
        ])
        let result = try ParagraphBlockEditor.replace(in: block, from: 1, to: 5, with: "X")
        guard case .paragraph(let inline) = result else {
            return XCTFail("result is not a paragraph: \(result)")
        }
        let raw = MarkdownSerializer.serializeInlines(inline)
        // "abc"="abc"; bold("bold")="bold"; "xyz"="xyz". Render order
        // gives offsets 0..9 → "abcboldxyz". Replace [1,5) with "X" →
        // before = "a"; deleted = "bcbo"; after = "ld" (still inside
        // bold) + "xyz". cleanInlines folds the trailing text("X")
        // adjacent to the surviving bold span, producing
        // [text("aX"), bold([text("ld")]), text("xyz")] which serializes
        // back to "aX**ld**xyz".
        XCTAssertEqual(raw, "aX**ld**xyz", "got \(raw); inline=\(inline)")
    }

    func test_replace_imageContainingParagraph_replacesAroundImage() throws {
        let block = Block.paragraph(inline: [
            .text("ab"),
            .image(alt: [.text("alt")], rawDestination: "u", width: nil),
            .text("cd")
        ])
        // Replace just the image (offset [2, 3)) with text "X".
        let result = try ParagraphBlockEditor.replace(in: block, from: 2, to: 3, with: "X")
        guard case .paragraph(let inline) = result else {
            return XCTFail("result is not a paragraph: \(result)")
        }
        for item in inline {
            if case .image = item { return XCTFail("image survived replace: \(inline)") }
        }
        let raw = MarkdownSerializer.serializeInlines(inline)
        XCTAssertEqual(raw, "abXcd", "got \(raw)")
    }

    func test_replace_onNonParagraphBlock_throws() {
        let block = Block.heading(level: 1, suffix: "h")
        XCTAssertThrowsError(try ParagraphBlockEditor.replace(in: block, from: 0, to: 1, with: "x"))
    }

    // MARK: - integration sanity: delegated path matches direct call

    /// `EditingOps.insert(_:at:in:)` for a single-paragraph projection
    /// should produce the SAME mutated block whether it goes through
    /// the dispatch switch or directly through `ParagraphBlockEditor`.
    /// Pin one case so we'd notice if the dispatch wrapper drifted.
    func test_integration_insertIntoBlock_paragraphSwitchMatchesDirectEditor() throws {
        let block = Block.paragraph(inline: [.text("hello world")])
        let direct = try ParagraphBlockEditor.insert(into: block, offsetInBlock: 5, string: ", X")
        // Build a one-block document to exercise the public EditingOps surface.
        let doc = Document(blocks: [block], trailingNewline: false)
        let bodyFont = PlatformFont.systemFont(ofSize: 14)
        let codeFont = PlatformFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        let projection = DocumentProjection(document: doc, bodyFont: bodyFont, codeFont: codeFont)
        // Locate "hello world" in the rendered text — paragraph render
        // is just the inline text, so storage position 5 == offsetInBlock 5.
        let result = try EditingOps.insert(", X", at: 5, in: projection)
        XCTAssertEqual(
            result.newProjection.document.blocks.first, direct,
            "EditingOps.insert and ParagraphBlockEditor.insert must produce the same block"
        )
    }
}
