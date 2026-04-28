//
//  BlockquoteReaderTests.swift
//  FSNotesTests
//
//  Phase 12.C.5 — Blockquote reader port tests.
//

import XCTest
@testable import FSNotes

final class BlockquoteReaderTests: XCTestCase {

    // MARK: - detect()

    func test_detect_basicMarker() {
        guard let r = BlockquoteReader.detect("> hello") else {
            return XCTFail("expected match")
        }
        XCTAssertEqual(r.prefix, "> ")
        XCTAssertEqual(r.content, "hello")
    }

    func test_detect_doubleMarker() {
        guard let r = BlockquoteReader.detect(">> hello") else {
            return XCTFail("expected match")
        }
        XCTAssertEqual(r.prefix, ">> ")
        XCTAssertEqual(r.content, "hello")
    }

    func test_detect_spacedDoubleMarker() {
        guard let r = BlockquoteReader.detect("> > hello") else {
            return XCTFail("expected match")
        }
        XCTAssertEqual(r.prefix, "> > ")
        XCTAssertEqual(r.content, "hello")
    }

    func test_detect_noPostMarkerSpace() {
        guard let r = BlockquoteReader.detect(">no space") else {
            return XCTFail("expected match")
        }
        XCTAssertEqual(r.prefix, ">")
        XCTAssertEqual(r.content, "no space")
    }

    func test_detect_emptyAfterMarker() {
        guard let r = BlockquoteReader.detect(">") else {
            return XCTFail("expected match")
        }
        XCTAssertEqual(r.prefix, ">")
        XCTAssertEqual(r.content, "")
    }

    func test_detect_extraSpaceInContent() {
        guard let r = BlockquoteReader.detect(">  two") else {
            return XCTFail("expected match")
        }
        XCTAssertEqual(r.prefix, "> ")
        XCTAssertEqual(r.content, " two")
    }

    func test_detect_acceptsUpTo3LeadingSpaces() {
        XCTAssertNotNil(BlockquoteReader.detect("   > leading"))
        XCTAssertNotNil(BlockquoteReader.detect("  > leading"))
        XCTAssertNotNil(BlockquoteReader.detect(" > leading"))
    }

    func test_detect_rejects4LeadingSpaces() {
        // 4+ leading spaces is indented code context, not blockquote.
        XCTAssertNil(BlockquoteReader.detect("    > too far"))
    }

    func test_detect_rejectsNonMarker() {
        XCTAssertNil(BlockquoteReader.detect("paragraph"))
        XCTAssertNil(BlockquoteReader.detect(""))
        XCTAssertNil(BlockquoteReader.detect("  paragraph"))
    }

    // CommonMark spec example #6: a tab immediately after `>` is
    // partially consumed — one virtual column serves as the optional
    // post-marker space, the rest belongs to the content.
    func test_detect_tabAfterMarker_spec6() {
        guard let r = BlockquoteReader.detect(">\t\tfoo") else {
            return XCTFail("expected match")
        }
        XCTAssertEqual(r.prefix, ">\t")
        // Tab at col 1 expands to 3 cols (col 1 → col 4); 1 col consumed
        // as the optional space, leaving 2 cols. Then the next tab at
        // col 4 expands to 4 cols. Final content: 2 leftover spaces +
        // 4 tab spaces + "foo" = "      foo" (6 spaces).
        XCTAssertEqual(r.content, "      foo")
    }

    // MARK: - innerAllowsLazyContinuation()

    func test_innerAllowsLazyContinuation_nonEmpty_paragraphContext() {
        XCTAssertTrue(BlockquoteReader.innerAllowsLazyContinuation(["hello"]))
        XCTAssertTrue(BlockquoteReader.innerAllowsLazyContinuation(["one", "two"]))
    }

    func test_innerAllowsLazyContinuation_emptyContext() {
        XCTAssertFalse(BlockquoteReader.innerAllowsLazyContinuation([]))
    }

    func test_innerAllowsLazyContinuation_blankTrailing_blocks() {
        XCTAssertFalse(BlockquoteReader.innerAllowsLazyContinuation(["hello", ""]))
        XCTAssertFalse(BlockquoteReader.innerAllowsLazyContinuation(["hello", "   "]))
    }

    func test_innerAllowsLazyContinuation_indentedCodeTrailing_blocks() {
        // Last non-blank with 4+ leading spaces = indented code context.
        XCTAssertFalse(BlockquoteReader.innerAllowsLazyContinuation(["    code"]))
        XCTAssertFalse(BlockquoteReader.innerAllowsLazyContinuation(["one", "    code"]))
    }

    func test_innerAllowsLazyContinuation_openCodeFence_blocks() {
        // Open fence inside the quote: lazy continuation would be code.
        XCTAssertFalse(BlockquoteReader.innerAllowsLazyContinuation(["```", "code"]))
    }

    func test_innerAllowsLazyContinuation_closedCodeFence_allows() {
        // Fence opened and closed: paragraph context resumes.
        XCTAssertTrue(BlockquoteReader.innerAllowsLazyContinuation(
            ["```", "code", "```", "para"]
        ))
    }

    // MARK: - read() — single-line + multi-line

    func test_read_singleLine() {
        let lines = ["> hello", "after"]
        let r = BlockquoteReader.read(
            lines: lines, from: 0, trailingNewline: false,
            parseInlines: { [Inline.text($0)] },
            interruptsLazyContinuation: { _ in true }
        )
        guard let result = r else { return XCTFail("expected match") }
        XCTAssertEqual(result.nextIndex, 1)
        guard case .blockquote(let qLines) = result.block else {
            return XCTFail("expected blockquote, got \(result.block)")
        }
        XCTAssertEqual(qLines.count, 1)
        XCTAssertEqual(qLines[0].prefix, "> ")
    }

    func test_read_multiLineWithExplicitMarkers() {
        let lines = ["> one", "> two", "after"]
        let r = BlockquoteReader.read(
            lines: lines, from: 0, trailingNewline: false,
            parseInlines: { [Inline.text($0)] },
            interruptsLazyContinuation: { _ in true }
        )
        guard let result = r else { return XCTFail("expected match") }
        XCTAssertEqual(result.nextIndex, 2)
        guard case .blockquote(let qLines) = result.block else {
            return XCTFail("expected blockquote")
        }
        XCTAssertEqual(qLines.count, 2)
    }

    func test_read_lazyContinuation_extendsBlockquote() {
        // Second line lacks `>` but still extends the paragraph (lazy).
        let lines = ["> hello", "world", "next"]
        let r = BlockquoteReader.read(
            lines: lines, from: 0, trailingNewline: false,
            parseInlines: { [Inline.text($0)] },
            // The "world" line is normal paragraph content (does not
            // open a new block) — so it must NOT be flagged as
            // interrupting lazy continuation.
            interruptsLazyContinuation: { line in
                line.hasPrefix("---") || line.isEmpty
            }
        )
        guard let result = r else { return XCTFail("expected match") }
        XCTAssertEqual(result.nextIndex, 3)
        guard case .blockquote(let qLines) = result.block else {
            return XCTFail("expected blockquote")
        }
        XCTAssertEqual(qLines.count, 3)
        // First two lines have explicit prefix, third is the lazy line.
        XCTAssertEqual(qLines[0].prefix, "> ")
        XCTAssertEqual(qLines[2].prefix, "")
    }

    func test_read_lazyContinuation_blockedByBlankLine() {
        // Blank line between >-prefixed line and unprefixed line: the
        // unprefixed line cannot lazy-continue because the inner
        // paragraph closed at the blank.
        let lines = ["> hello", ">", "world"]
        let r = BlockquoteReader.read(
            lines: lines, from: 0, trailingNewline: false,
            parseInlines: { [Inline.text($0)] },
            interruptsLazyContinuation: { line in line.isEmpty }
        )
        guard let result = r else { return XCTFail("expected match") }
        // Only the two >-prefixed lines belong to the quote.
        XCTAssertEqual(result.nextIndex, 2)
    }

    func test_read_lazyContinuation_blockedWhenLineInterrupts() {
        // Second line is "---" (HR/setext underline) — must NOT lazy-
        // continue.
        let lines = ["> hello", "---"]
        let r = BlockquoteReader.read(
            lines: lines, from: 0, trailingNewline: false,
            parseInlines: { [Inline.text($0)] },
            interruptsLazyContinuation: { line in line.hasPrefix("---") }
        )
        guard let result = r else { return XCTFail("expected match") }
        XCTAssertEqual(result.nextIndex, 1)
    }

    func test_read_returnsNil_whenNotBlockquote() {
        let lines = ["paragraph"]
        XCTAssertNil(BlockquoteReader.read(
            lines: lines, from: 0, trailingNewline: false,
            parseInlines: { [Inline.text($0)] },
            interruptsLazyContinuation: { _ in true }
        ))
    }

    func test_read_skipsTrailingSyntheticEmptyLine() {
        // Input "> hello\n" splits to ["> hello", ""]. Reader should
        // not absorb the synthetic empty line as a quote line.
        let lines = ["> hello", ""]
        let r = BlockquoteReader.read(
            lines: lines, from: 0, trailingNewline: true,
            parseInlines: { [Inline.text($0)] },
            interruptsLazyContinuation: { _ in true }
        )
        guard let result = r else { return XCTFail("expected match") }
        XCTAssertEqual(result.nextIndex, 1)
    }

    // MARK: - End-to-end via MarkdownParser.parse

    func test_endToEnd_simpleBlockquote() {
        let doc = MarkdownParser.parse("> hello\n")
        XCTAssertEqual(doc.blocks.count, 1)
        guard case .blockquote(let qLines) = doc.blocks[0] else {
            return XCTFail("expected blockquote, got \(doc.blocks)")
        }
        XCTAssertEqual(qLines.count, 1)
        XCTAssertEqual(qLines[0].prefix, "> ")
    }

    func test_endToEnd_lazyContinuation() {
        let doc = MarkdownParser.parse("> hello\nworld\n")
        XCTAssertEqual(doc.blocks.count, 1)
        guard case .blockquote(let qLines) = doc.blocks[0] else {
            return XCTFail("expected blockquote, got \(doc.blocks)")
        }
        XCTAssertEqual(qLines.count, 2)
        XCTAssertEqual(qLines[0].prefix, "> ")
        XCTAssertEqual(qLines[1].prefix, "")
    }

    func test_endToEnd_quoteThenParagraph() {
        // Blank line after the quote terminates it.
        let doc = MarkdownParser.parse("> hello\n\nafter\n")
        XCTAssertEqual(doc.blocks.count, 3)
        guard case .blockquote = doc.blocks[0] else {
            return XCTFail("expected blockquote")
        }
        guard case .blankLine = doc.blocks[1] else {
            return XCTFail("expected blankLine")
        }
        guard case .paragraph = doc.blocks[2] else {
            return XCTFail("expected paragraph")
        }
    }

    func test_endToEnd_nestedQuoteShape() {
        let doc = MarkdownParser.parse("> > nested\n")
        XCTAssertEqual(doc.blocks.count, 1)
        guard case .blockquote(let qLines) = doc.blocks[0] else {
            return XCTFail("expected blockquote")
        }
        XCTAssertEqual(qLines.count, 1)
        XCTAssertEqual(qLines[0].prefix, "> > ")
    }

    func test_endToEnd_quoteRoundTripsBackToInput() {
        // Round-trip: the prefix is captured verbatim so serialize
        // reproduces the input.
        let input = "> hello\n> world\n"
        let doc = MarkdownParser.parse(input)
        let output = MarkdownSerializer.serialize(doc)
        XCTAssertEqual(output, input)
    }
}
