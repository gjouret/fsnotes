//
//  SuperscriptSubscriptTests.swift
//  FSNotesTests
//
//  Bug #17: <sup>…</sup> and <sub>…</sub> support in the block-model
//  inline tree. These tests pin three contracts:
//
//  1. Round-trip: serialize(parse(md)) == md for sup/sub markdown.
//  2. Tree shape: parse produces .superscript / .subscript nodes
//     wrapping the inner inlines (not raw <sup>/<sub> rawHTML strings).
//  3. Render: InlineRenderer.render emits NSAttributedString with the
//     .superscript attribute set (+1 for sup, -1 for sub) plus a
//     reduced font size — so the glyph actually appears raised/lowered.
//
//  All tests are pure-function tests (no NSWindow, no field editor)
//  per CLAUDE.md rule 3.
//

import XCTest
@testable import FSNotes

class SuperscriptSubscriptTests: XCTestCase {

    private let body: NSFont = NSFont.systemFont(ofSize: 14)
    private var baseAttrs: [NSAttributedString.Key: Any] {
        return [.font: body, .foregroundColor: NSColor.textColor]
    }

    // MARK: - Round-trip (parse + serialize is byte-equal)

    func test_roundTrip_simpleSuperscript() {
        let md = "x<sup>2</sup>\n"
        let doc = MarkdownParser.parse(md)
        let serialized = MarkdownSerializer.serialize(doc)
        XCTAssertEqual(serialized, md)
    }

    func test_roundTrip_simpleSubscript() {
        let md = "H<sub>2</sub>O\n"
        let doc = MarkdownParser.parse(md)
        let serialized = MarkdownSerializer.serialize(doc)
        XCTAssertEqual(serialized, md)
    }

    func test_roundTrip_supAndSubInSameParagraph() {
        let md = "E = mc<sup>2</sup> and H<sub>2</sub>O\n"
        let doc = MarkdownParser.parse(md)
        let serialized = MarkdownSerializer.serialize(doc)
        XCTAssertEqual(serialized, md)
    }

    func test_roundTrip_supWithBoldInside() {
        let md = "x<sup>**n**</sup>\n"
        let doc = MarkdownParser.parse(md)
        let serialized = MarkdownSerializer.serialize(doc)
        XCTAssertEqual(serialized, md)
    }

    func test_roundTrip_supInsideBold() {
        let md = "**x<sup>2</sup>**\n"
        let doc = MarkdownParser.parse(md)
        let serialized = MarkdownSerializer.serialize(doc)
        XCTAssertEqual(serialized, md)
    }

    // MARK: - Parse tree shape

    func test_parse_producesSuperscriptInlineNode() {
        let doc = MarkdownParser.parse("x<sup>2</sup>")
        guard case .paragraph(let inlines) = doc.blocks[0] else {
            XCTFail("Expected paragraph block, got \(doc.blocks[0])")
            return
        }
        // Expect: [.text("x"), .superscript([.text("2")])]
        XCTAssertEqual(inlines.count, 2, "Expected 2 inline nodes, got \(inlines.count): \(inlines)")
        guard case .superscript(let inner) = inlines[1] else {
            XCTFail("Expected .superscript node at index 1, got \(inlines[1])")
            return
        }
        XCTAssertEqual(inner.count, 1)
        if case .text(let s) = inner[0] {
            XCTAssertEqual(s, "2")
        } else {
            XCTFail("Expected .text inside .superscript, got \(inner[0])")
        }
    }

    func test_parse_producesSubscriptInlineNode() {
        let doc = MarkdownParser.parse("H<sub>2</sub>O")
        guard case .paragraph(let inlines) = doc.blocks[0] else {
            XCTFail("Expected paragraph block, got \(doc.blocks[0])")
            return
        }
        // Expect: [.text("H"), .subscript([.text("2")]), .text("O")]
        XCTAssertEqual(inlines.count, 3, "Expected 3 inline nodes, got \(inlines.count): \(inlines)")
        guard case .`subscript`(let inner) = inlines[1] else {
            XCTFail("Expected .subscript node at index 1, got \(inlines[1])")
            return
        }
        XCTAssertEqual(inner.count, 1)
        if case .text(let s) = inner[0] {
            XCTAssertEqual(s, "2")
        } else {
            XCTFail("Expected .text inside .subscript, got \(inner[0])")
        }
    }

    // MARK: - Render emits .superscript attribute + reduced font

    func test_render_superscriptSetsSuperscriptAttributeAndShrinksFont() {
        let tree: [Inline] = [.text("x"), .superscript([.text("2")])]
        let rendered = InlineRenderer.render(tree, baseAttributes: baseAttrs)
        XCTAssertEqual(rendered.string, "x2")
        // Position 0 ("x") should have NO superscript attribute and the
        // base font size.
        let supAtX = rendered.attribute(.superscript, at: 0, effectiveRange: nil) as? Int
        XCTAssertTrue(supAtX == nil || supAtX == 0, "Base text should not have superscript attribute")
        let fontAtX = rendered.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertNotNil(fontAtX)
        XCTAssertEqual(fontAtX!.pointSize, body.pointSize, accuracy: 0.01)

        // Position 1 ("2") should have superscript == 1 and a smaller font.
        let supAt2 = rendered.attribute(.superscript, at: 1, effectiveRange: nil) as? Int
        XCTAssertEqual(supAt2, 1, "Superscript glyph should have .superscript = 1")
        let fontAt2 = rendered.attribute(.font, at: 1, effectiveRange: nil) as? NSFont
        XCTAssertNotNil(fontAt2)
        XCTAssertLessThan(fontAt2!.pointSize, body.pointSize, "Superscript font should be smaller than base")
    }

    func test_render_subscriptSetsSuperscriptAttributeNegative() {
        let tree: [Inline] = [.text("H"), .`subscript`([.text("2")]), .text("O")]
        let rendered = InlineRenderer.render(tree, baseAttributes: baseAttrs)
        XCTAssertEqual(rendered.string, "H2O")
        // "2" at index 1 should have superscript == -1.
        let supAt2 = rendered.attribute(.superscript, at: 1, effectiveRange: nil) as? Int
        XCTAssertEqual(supAt2, -1, "Subscript glyph should have .superscript = -1")
        let fontAt2 = rendered.attribute(.font, at: 1, effectiveRange: nil) as? NSFont
        XCTAssertLessThan(fontAt2!.pointSize, body.pointSize, "Subscript font should be smaller than base")
        // "O" at index 2 should be back to base size, no superscript.
        let supAtO = rendered.attribute(.superscript, at: 2, effectiveRange: nil) as? Int
        XCTAssertTrue(supAtO == nil || supAtO == 0)
        let fontAtO = rendered.attribute(.font, at: 2, effectiveRange: nil) as? NSFont
        XCTAssertNotNil(fontAtO)
        XCTAssertEqual(fontAtO!.pointSize, body.pointSize, accuracy: 0.01)
    }

    // MARK: - Converter (round-trip through inlineTreeFromAttributedString)

    func test_converter_roundTripSuperscript() {
        let tree: [Inline] = [.text("x"), .superscript([.text("2")])]
        let rendered = InlineRenderer.render(tree, baseAttributes: baseAttrs)
        let recovered = InlineRenderer.inlineTreeFromAttributedString(rendered)
        // The converter merges adjacent text spans, so we expect
        // [.text("x"), .superscript([.text("2")])].
        XCTAssertEqual(recovered.count, 2, "Expected 2 nodes, got \(recovered)")
        if case .text(let s) = recovered[0] {
            XCTAssertEqual(s, "x")
        } else {
            XCTFail("Expected .text at index 0, got \(recovered[0])")
        }
        if case .superscript(let inner) = recovered[1] {
            XCTAssertEqual(inner.count, 1)
            if case .text(let s) = inner[0] {
                XCTAssertEqual(s, "2")
            } else {
                XCTFail("Expected .text inside .superscript")
            }
        } else {
            XCTFail("Expected .superscript at index 1, got \(recovered[1])")
        }
    }

    func test_converter_roundTripSubscript() {
        let tree: [Inline] = [.text("H"), .`subscript`([.text("2")]), .text("O")]
        let rendered = InlineRenderer.render(tree, baseAttributes: baseAttrs)
        let recovered = InlineRenderer.inlineTreeFromAttributedString(rendered)
        XCTAssertEqual(recovered.count, 3, "Expected 3 nodes, got \(recovered)")
        if case .`subscript`(let inner) = recovered[1] {
            XCTAssertEqual(inner.count, 1)
            if case .text(let s) = inner[0] {
                XCTAssertEqual(s, "2")
            } else {
                XCTFail("Expected .text inside .subscript")
            }
        } else {
            XCTFail("Expected .subscript at index 1, got \(recovered[1])")
        }
    }
}
