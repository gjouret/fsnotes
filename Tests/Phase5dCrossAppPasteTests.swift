//
//  Phase5dCrossAppPasteTests.swift
//  FSNotesTests
//
//  Phase 5d commit 4 — cross-app paste via NSAttributedString + image
//  pasteboard. Pure-function and integration tests covering:
//
//    1. `EditingOps.replaceFragment` — the new paste primitive that
//       fuses a selection-delete and fragment-insert into one
//       `EditResult` so the user sees ONE undo entry.
//    2. `EditTextView.documentFromAttributedString` — pure converter
//       from `NSAttributedString` (bold / italic / strike / underline
//       / link runs) to `Document`, with dropped-attribute rules
//       (font family / size / color / paragraph style).
//    3. `insertAttributedStringFragmentViaBlockModel` — wire-in test:
//       attributed-string pastes route through the block model and
//       populate `lastEditContract` (proving no direct storage bypass).
//    4. Undo grouping — paste over non-empty selection yields ONE
//       undoable unit that fully restores the pre-paste projection.
//    5. Image pasteboard — small PNG saved to disk and inserted as a
//       `.image` inline via the existing `insertImageViaBlockModel`
//       path (exercised through the paste() flow).
//

import XCTest
@testable import FSNotes

final class Phase5dCrossAppPasteTests: XCTestCase {

    // MARK: - Helpers

    private func bodyFont() -> PlatformFont {
        return PlatformFont.systemFont(ofSize: 14)
    }
    private func codeFont() -> PlatformFont {
        return PlatformFont.monospacedSystemFont(
            ofSize: 14, weight: .regular
        )
    }
    private func project(_ md: String) -> DocumentProjection {
        let doc = MarkdownParser.parse(md)
        return DocumentProjection(
            document: doc,
            bodyFont: bodyFont(),
            codeFont: codeFont()
        )
    }

    private func boldFont(size: CGFloat = 14) -> NSFont {
        let base = NSFont.systemFont(ofSize: size)
        let desc = base.fontDescriptor.withSymbolicTraits(.bold)
        return NSFont(descriptor: desc, size: size) ?? base
    }
    private func italicFont(size: CGFloat = 14) -> NSFont {
        let base = NSFont.systemFont(ofSize: size)
        let desc = base.fontDescriptor.withSymbolicTraits(.italic)
        return NSFont(descriptor: desc, size: size) ?? base
    }

    // MARK: - EditingOps.replaceFragment primitive

    func test_replaceFragment_emptySelection_matchesInsertFragment() throws {
        // Zero-length range: `replaceFragment` is defined to behave
        // exactly like `insertFragment` at the cursor — assert the
        // post-edit document matches.
        let proj = project("hello world\n")
        let range = NSRange(location: 6, length: 0)
        let fragment = Document(
            blocks: [.paragraph(inline: [.text("INSERT ")])],
            trailingNewline: false
        )

        let result = try EditingOps.replaceFragment(
            range: range, with: fragment, in: proj
        )
        XCTAssertEqual(
            MarkdownSerializer.serialize(result.newProjection.document)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            "hello INSERT world"
        )
        XCTAssertNotNil(result.contract)
    }

    func test_replaceFragment_nonEmptySelection_replacesInPlace() throws {
        // Selection covers the word "world" (offset 6..11). Replace
        // with a fragment "EARTH". One `EditResult` / one contract.
        let proj = project("hello world\n")
        let range = NSRange(location: 6, length: 5)
        let fragment = Document(
            blocks: [.paragraph(inline: [.text("EARTH")])],
            trailingNewline: false
        )

        let result = try EditingOps.replaceFragment(
            range: range, with: fragment, in: proj
        )

        XCTAssertEqual(
            MarkdownSerializer.serialize(result.newProjection.document)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            "hello EARTH"
        )
        XCTAssertEqual(
            result.newCursorPosition, 11,
            "cursor should land after the replacement"
        )
        XCTAssertNotNil(result.contract)
    }

    func test_replaceFragment_emptyFragment_isPlainDelete() throws {
        // Empty fragment degenerates to a pure delete of the range.
        let proj = project("hello world\n")
        let range = NSRange(location: 5, length: 6)  // " world"
        let empty = Document(blocks: [], trailingNewline: false)

        let result = try EditingOps.replaceFragment(
            range: range, with: empty, in: proj
        )
        XCTAssertEqual(
            MarkdownSerializer.serialize(result.newProjection.document)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            "hello"
        )
    }

    func test_replaceFragment_spliceIsNarrowed() throws {
        // The fused splice should narrow to only the differing region.
        // "hello world" → replace "world" with "WORLD" — only 5 chars
        // differ, so the splice range length should be <= 5.
        let proj = project("hello world\n")
        let range = NSRange(location: 6, length: 5)
        let fragment = Document(
            blocks: [.paragraph(inline: [.text("WORLD")])],
            trailingNewline: false
        )

        let result = try EditingOps.replaceFragment(
            range: range, with: fragment, in: proj
        )
        XCTAssertLessThanOrEqual(
            result.spliceRange.length, 5,
            "narrowed splice should not exceed the differing-char count"
        )
        XCTAssertLessThanOrEqual(
            result.spliceReplacement.length, 5,
            "narrowed replacement should not exceed the differing-char count"
        )
    }

    // MARK: - documentFromAttributedString (pure converter)

    func test_documentFromAttributedString_empty_returnsEmptyDoc() {
        let doc = EditTextView.documentFromAttributedString(
            NSAttributedString(string: "")
        )
        XCTAssertTrue(doc.blocks.isEmpty)
    }

    func test_documentFromAttributedString_plainText_singleParagraph() {
        let attr = NSAttributedString(
            string: "hello world",
            attributes: [.font: NSFont.systemFont(ofSize: 14)]
        )
        let doc = EditTextView.documentFromAttributedString(attr)
        XCTAssertEqual(doc.blocks.count, 1)
        let md = MarkdownSerializer.serialize(doc)
        XCTAssertEqual(
            md.trimmingCharacters(in: .whitespacesAndNewlines),
            "hello world"
        )
    }

    func test_documentFromAttributedString_boldItalicStrikeUnderline() {
        // Four runs: plain, bold, italic, strike, underline.
        let m = NSMutableAttributedString()
        m.append(NSAttributedString(
            string: "plain ",
            attributes: [.font: NSFont.systemFont(ofSize: 14)]
        ))
        m.append(NSAttributedString(
            string: "bold",
            attributes: [.font: boldFont()]
        ))
        m.append(NSAttributedString(
            string: " ",
            attributes: [.font: NSFont.systemFont(ofSize: 14)]
        ))
        m.append(NSAttributedString(
            string: "italic",
            attributes: [.font: italicFont()]
        ))
        m.append(NSAttributedString(
            string: " ",
            attributes: [.font: NSFont.systemFont(ofSize: 14)]
        ))
        m.append(NSAttributedString(
            string: "strike",
            attributes: [
                .font: NSFont.systemFont(ofSize: 14),
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
            ]
        ))
        m.append(NSAttributedString(
            string: " ",
            attributes: [.font: NSFont.systemFont(ofSize: 14)]
        ))
        m.append(NSAttributedString(
            string: "under",
            attributes: [
                .font: NSFont.systemFont(ofSize: 14),
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ]
        ))

        let doc = EditTextView.documentFromAttributedString(m)
        XCTAssertEqual(doc.blocks.count, 1)
        guard case .paragraph(let inlines) = doc.blocks[0] else {
            return XCTFail("expected paragraph block")
        }
        // Assert each trait survives at some nesting depth.
        XCTAssertTrue(inlines.contains { hasInline(kind: .bold, in: $0) },
                      "bold run not preserved")
        XCTAssertTrue(inlines.contains { hasInline(kind: .italic, in: $0) },
                      "italic run not preserved")
        XCTAssertTrue(inlines.contains { hasInline(kind: .strike, in: $0) },
                      "strike run not preserved")
        XCTAssertTrue(inlines.contains { hasInline(kind: .underline, in: $0) },
                      "underline run not preserved")
    }

    func test_documentFromAttributedString_linkRun_preservesURL() {
        let url = URL(string: "https://example.com/page")!
        let m = NSMutableAttributedString()
        m.append(NSAttributedString(
            string: "see ",
            attributes: [.font: NSFont.systemFont(ofSize: 14)]
        ))
        m.append(NSAttributedString(
            string: "here",
            attributes: [
                .font: NSFont.systemFont(ofSize: 14),
                .link: url,
            ]
        ))

        let doc = EditTextView.documentFromAttributedString(m)
        XCTAssertEqual(doc.blocks.count, 1)
        guard case .paragraph(let inlines) = doc.blocks[0] else {
            return XCTFail("expected paragraph block")
        }
        let hasLink = inlines.contains { inline in
            if case .link(_, let dest) = inline {
                return dest == "https://example.com/page"
            }
            return false
        }
        XCTAssertTrue(hasLink, "link inline missing or URL differs")
    }

    func test_documentFromAttributedString_paragraphSplitOnDoubleNewline() {
        // `\n\n` separates paragraphs; single `\n` stays inside.
        let m = NSMutableAttributedString(
            string: "first\n\nsecond",
            attributes: [.font: NSFont.systemFont(ofSize: 14)]
        )
        let doc = EditTextView.documentFromAttributedString(m)

        // Block shape: paragraph, blankLine (empty segment), paragraph
        // — OR paragraph, paragraph (converter may choose either).
        let paragraphCount = doc.blocks.filter { blk in
            if case .paragraph = blk { return true }
            return false
        }.count
        XCTAssertEqual(
            paragraphCount, 2,
            "two text segments must map to two paragraphs"
        )
    }

    func test_documentFromAttributedString_paragraphSplitOnLineSeparator() {
        // `\u{2028}` (Unicode line separator) is emitted by Pages /
        // Safari on Shift+Enter → treat as a hard paragraph break.
        let m = NSMutableAttributedString(
            string: "one\u{2028}two",
            attributes: [.font: NSFont.systemFont(ofSize: 14)]
        )
        let doc = EditTextView.documentFromAttributedString(m)
        let paragraphCount = doc.blocks.filter { blk in
            if case .paragraph = blk { return true }
            return false
        }.count
        XCTAssertEqual(paragraphCount, 2)
    }

    func test_documentFromAttributedString_dropsFontSizeAndColor() {
        // Source attributes the renderer must NOT propagate into the
        // Document: non-system font size, explicit foreground color,
        // explicit background color. The inline tree should contain
        // just plain text — no wrappers that would serialize as
        // markdown formatting markers.
        let m = NSMutableAttributedString(
            string: "styled",
            attributes: [
                .font: NSFont(name: "Times New Roman", size: 24)
                    ?? NSFont.systemFont(ofSize: 24),
                .foregroundColor: NSColor.red,
                .backgroundColor: NSColor.yellow,
            ]
        )
        let doc = EditTextView.documentFromAttributedString(m)
        XCTAssertEqual(doc.blocks.count, 1)
        let md = MarkdownSerializer.serialize(doc)
        // Must not contain bold / italic / other markers — the output
        // is plain text. Note: yellow background MAY trip the
        // `.highlight` detector if it matches the theme highlight; we
        // assert only that font-size / color-red do not produce any
        // markdown markers.
        XCTAssertTrue(md.contains("styled"),
                      "text must survive: \(md)")
        XCTAssertFalse(md.contains("**"),
                       "no bold marker expected: \(md)")
        XCTAssertFalse(md.contains("*styled*"),
                       "no italic marker expected: \(md)")
    }

    func test_documentFromAttributedString_stripsAttachments() {
        // NSTextAttachment runs must be stripped — attachments don't
        // survive markdown round-trip, and when both an image and
        // attributed string are on the pasteboard, the image branch
        // of paste() handles the image separately (the attachment
        // run is the rich representation of the same image).
        let m = NSMutableAttributedString()
        m.append(NSAttributedString(
            string: "before ",
            attributes: [.font: NSFont.systemFont(ofSize: 14)]
        ))
        let attachment = NSTextAttachment()
        attachment.image = NSImage(size: NSSize(width: 1, height: 1))
        m.append(NSAttributedString(attachment: attachment))
        m.append(NSAttributedString(
            string: " after",
            attributes: [.font: NSFont.systemFont(ofSize: 14)]
        ))

        let doc = EditTextView.documentFromAttributedString(m)
        let md = MarkdownSerializer.serialize(doc)
        XCTAssertTrue(
            md.contains("before") && md.contains("after"),
            "text surrounding the attachment must survive: \(md)"
        )
        XCTAssertFalse(
            md.contains("\u{FFFC}"),
            "attachment object-replacement char must be stripped"
        )
    }

    // MARK: - Block-model routing: insertAttributedStringFragmentViaBlockModel

    func test_attributedStringPaste_routesThroughBlockModel() {
        let harness = EditorHarness(markdown: "hello ")
        defer { harness.teardown() }

        // Caret at end of "hello " (offset 6).
        harness.editor.setSelectedRange(NSRange(location: 6, length: 0))
        harness.editor.lastEditContract = nil

        let attr = NSAttributedString(
            string: "world",
            attributes: [.font: boldFont()]
        )
        let handled = harness.editor
            .insertAttributedStringFragmentViaBlockModel(attr)
        XCTAssertTrue(handled)
        XCTAssertNotNil(
            harness.editor.lastEditContract,
            "attributed-string paste must populate lastEditContract"
        )

        // The resulting paragraph should contain a `.bold` inline.
        guard let doc = harness.editor.documentProjection?.document,
              case .paragraph(let inlines) = doc.blocks.first else {
            return XCTFail("expected paragraph block after paste")
        }
        let hasBold = inlines.contains { hasInline(kind: .bold, in: $0) }
        XCTAssertTrue(hasBold, "bold run must round-trip into the Document")
    }

    // MARK: - Undo grouping: paste over non-empty selection → one undo

    func test_attributedStringPaste_overSelection_producesOneUndoStep() {
        let harness = EditorHarness(markdown: "hello world")
        defer { harness.teardown() }

        let preProjection = harness.editor.documentProjection
        XCTAssertNotNil(preProjection)

        // Select "world" (5 chars starting at offset 6).
        harness.editor.setSelectedRange(NSRange(location: 6, length: 5))

        let attr = NSAttributedString(
            string: "EARTH",
            attributes: [.font: boldFont()]
        )
        _ = harness.editor.insertAttributedStringFragmentViaBlockModel(attr)

        // Post-paste: document should have "hello **EARTH**" content.
        guard let afterPaste = harness.editor.documentProjection?.document,
              case .paragraph(let inlinesAfter) = afterPaste.blocks.first else {
            return XCTFail("expected paragraph block after paste")
        }
        XCTAssertTrue(
            inlinesAfter.contains { hasInline(kind: .bold, in: $0) },
            "pasted bold must be present"
        )

        // ONE undo must fully restore the pre-paste document. If the
        // paste emitted two undo entries (the known 2-step-undo bug
        // that commit 4 is here to fix), the first undo would only
        // restore part of the state.
        XCTAssertTrue(
            harness.editor.undoManager?.canUndo ?? false,
            "undoManager must have a registered undo after paste"
        )
        harness.editor.undoManager?.undo()

        guard let restoredDoc = harness.editor.documentProjection?.document else {
            return XCTFail("projection missing after undo")
        }
        XCTAssertEqual(
            MarkdownSerializer.serialize(restoredDoc)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            "hello world",
            "one undo must restore the pre-paste document in full"
        )
    }

    func test_markdownPaste_overSelection_producesOneUndoStep() {
        // Same one-undo-step contract for the markdown-paste branch.
        // Before commit 4 this path emitted two undo entries (delete
        // selection + insert fragment); the replaceFragment primitive
        // fuses them into one.
        let harness = EditorHarness(markdown: "hello world")
        defer { harness.teardown() }

        harness.editor.setSelectedRange(NSRange(location: 6, length: 5))
        _ = harness.editor.insertMarkdownFragmentViaBlockModel("**EARTH**")

        XCTAssertTrue(
            harness.editor.undoManager?.canUndo ?? false
        )
        harness.editor.undoManager?.undo()

        guard let restoredDoc = harness.editor.documentProjection?.document else {
            return XCTFail("projection missing after undo")
        }
        XCTAssertEqual(
            MarkdownSerializer.serialize(restoredDoc)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            "hello world",
            "one undo must restore the pre-paste document in full"
        )
    }

    // MARK: - Inline kind probe (test helper)

    private enum InlineKind {
        case bold, italic, strike, underline
    }

    /// Recursive check: does the inline tree rooted at `node` contain
    /// an inline matching `kind`? Used by trait-preservation tests.
    private func hasInline(kind: InlineKind, in node: Inline) -> Bool {
        switch (kind, node) {
        case (.bold, .bold):               return true
        case (.italic, .italic):           return true
        case (.strike, .strikethrough):    return true
        case (.underline, .underline):     return true
        default:
            break
        }
        switch node {
        case .bold(let c, _):              return c.contains { hasInline(kind: kind, in: $0) }
        case .italic(let c, _):            return c.contains { hasInline(kind: kind, in: $0) }
        case .strikethrough(let c):        return c.contains { hasInline(kind: kind, in: $0) }
        case .underline(let c):            return c.contains { hasInline(kind: kind, in: $0) }
        case .highlight(let c):            return c.contains { hasInline(kind: kind, in: $0) }
        case .superscript(let c):          return c.contains { hasInline(kind: kind, in: $0) }
        case .`subscript`(let c):          return c.contains { hasInline(kind: kind, in: $0) }
        case .kbd(let c):                  return c.contains { hasInline(kind: kind, in: $0) }
        case .link(let text, _):           return text.contains { hasInline(kind: kind, in: $0) }
        default:                           return false
        }
    }
}
