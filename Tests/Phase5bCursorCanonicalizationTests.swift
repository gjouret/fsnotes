//
//  Phase5bCursorCanonicalizationTests.swift
//  FSNotesTests
//
//  Phase 5b — cursor canonicalization.
//
//  Pure-function tests covering the `DocumentCursor ↔ NSTextLocation`
//  translation layer and the `DocumentRange` value type. These tests do
//  not require an `NSWindow`, a field editor, or any view glue — they
//  construct a minimal `NSTextContentStorage` + `DocumentProjection`
//  fixture and exercise the conversions directly.
//
//  The live editor's `setSelectedRanges` interception is covered
//  indirectly: any editor test that does WYSIWYG typing now round-trips
//  every selection change through `DocumentRange`, so an incorrect
//  conversion would break that suite. The explicit `setSelectedRanges`
//  no-op-roundtrip test here is a belt-and-braces pin against future
//  drift.
//

import XCTest
@testable import FSNotes

#if os(OSX)
import AppKit
#else
import UIKit
#endif

final class Phase5bCursorCanonicalizationTests: XCTestCase {

    // MARK: - Fixture

    private func bodyFont() -> PlatformFont {
        PlatformFont.systemFont(ofSize: 14)
    }
    private func codeFont() -> PlatformFont {
        PlatformFont.monospacedSystemFont(ofSize: 14, weight: .regular)
    }

    /// Build a `(projection, contentStorage)` pair for a given markdown
    /// string. The content storage is fully initialized (attributed
    /// string set inside a `performEditingTransaction`) so its
    /// `documentRange` covers `0 ..< attributed.length`.
    private func fixture(
        _ markdown: String
    ) -> (DocumentProjection, NSTextContentStorage) {
        let doc = MarkdownParser.parse(markdown)
        let projection = DocumentProjection(
            document: doc, bodyFont: bodyFont(), codeFont: codeFont()
        )
        let cs = NSTextContentStorage()
        cs.performEditingTransaction {
            cs.textStorage?.setAttributedString(projection.attributed)
        }
        return (projection, cs)
    }

    // MARK: - DocumentCursor → NSTextLocation → DocumentCursor round-trip

    /// Canonical two-block fixture: "hello\n\nworld\n" renders as
    /// three blocks (para, blank, para) with block 2 ("world")
    /// starting at storage index 7. Using the blank-line form rather
    /// than a single newline avoids ambiguity over how the parser
    /// splits adjacent lines.
    private let twoParagraphMarkdown = "hello\n\nworld\n"

    func test_cursor_to_location_roundtrip_firstBlockStart() {
        let (p, cs) = fixture(twoParagraphMarkdown)
        let cursor = DocumentCursor(blockIndex: 0, inlineOffset: 0)
        guard let loc = cursor.toTextLocation(in: cs, using: p) else {
            return XCTFail("expected a valid NSTextLocation")
        }
        let roundTrip = DocumentCursor.from(
            textLocation: loc, in: cs, using: p
        )
        XCTAssertEqual(roundTrip, cursor)
    }

    func test_cursor_to_location_roundtrip_middleOfBlock() {
        let (p, cs) = fixture(twoParagraphMarkdown)
        let cursor = DocumentCursor(blockIndex: 0, inlineOffset: 3)
        guard let loc = cursor.toTextLocation(in: cs, using: p) else {
            return XCTFail("expected a valid NSTextLocation")
        }
        let roundTrip = DocumentCursor.from(
            textLocation: loc, in: cs, using: p
        )
        XCTAssertEqual(roundTrip, cursor)
    }

    func test_cursor_to_location_roundtrip_secondBlock() {
        let (p, cs) = fixture(twoParagraphMarkdown)
        // Block 2 ("world") — two paragraphs separated by blank line,
        // so index 1 is the blank-line block, index 2 is "world".
        XCTAssertGreaterThanOrEqual(p.blockSpans.count, 2)
        let lastBlock = p.blockSpans.count - 1
        let cursor = DocumentCursor(blockIndex: lastBlock, inlineOffset: 2)
        guard let loc = cursor.toTextLocation(in: cs, using: p) else {
            return XCTFail("expected a valid NSTextLocation")
        }
        let roundTrip = DocumentCursor.from(
            textLocation: loc, in: cs, using: p
        )
        XCTAssertEqual(roundTrip, cursor)
    }

    func test_cursor_to_location_roundtrip_endOfLastBlock() {
        let (p, cs) = fixture(twoParagraphMarkdown)
        // Cursor at the end of "world" — inlineOffset equals the
        // block's rendered length.
        let lastSpan = p.blockSpans.last!
        let cursor = DocumentCursor(
            blockIndex: p.blockSpans.count - 1,
            inlineOffset: lastSpan.length
        )
        guard let loc = cursor.toTextLocation(in: cs, using: p) else {
            return XCTFail("expected a valid NSTextLocation")
        }
        let roundTrip = DocumentCursor.from(
            textLocation: loc, in: cs, using: p
        )
        XCTAssertEqual(roundTrip, cursor)
    }

    func test_cursor_to_location_roundtrip_emptyBlock() {
        // Two paragraphs separated by a blank line — the blank line is
        // a zero-length block that lives at the storage offset of the
        // first separator newline.
        let (p, cs) = fixture("a\n\nb\n")
        XCTAssertEqual(p.blockSpans.count, 3, "expected 3 blocks (para, blank, para)")
        XCTAssertEqual(p.blockSpans[1].length, 0, "expected middle blank to be zero-length")
        let cursor = DocumentCursor(blockIndex: 1, inlineOffset: 0)
        guard let loc = cursor.toTextLocation(in: cs, using: p) else {
            return XCTFail("expected a valid NSTextLocation")
        }
        let roundTrip = DocumentCursor.from(
            textLocation: loc, in: cs, using: p
        )
        // Round-trip is identity: `blockContaining`'s binary search
        // prefers the later block when two non-overlapping spans
        // share the same `.location` (one of length 0, one that
        // starts after it). The zero-length blank block at
        // `spans[1].location` is returned over the first paragraph
        // whose span ends one position earlier.
        XCTAssertEqual(roundTrip, cursor)
    }

    // MARK: - NSTextLocation → DocumentCursor → NSTextLocation round-trip

    func test_location_to_cursor_roundtrip_documentStart() {
        let (p, cs) = fixture(twoParagraphMarkdown)
        let start = cs.documentRange.location
        guard let cursor = DocumentCursor.from(
            textLocation: start, in: cs, using: p
        ) else { return XCTFail("expected a valid DocumentCursor") }
        guard let backLoc = cursor.toTextLocation(in: cs, using: p) else {
            return XCTFail("expected a valid NSTextLocation")
        }
        XCTAssertEqual(
            cs.offset(from: start, to: backLoc), 0,
            "expected round-tripped location to match original"
        )
    }

    func test_location_to_cursor_roundtrip_documentEnd() {
        let (p, cs) = fixture(twoParagraphMarkdown)
        let end = cs.documentRange.endLocation
        guard let cursor = DocumentCursor.from(
            textLocation: end, in: cs, using: p
        ) else { return XCTFail("expected a valid DocumentCursor") }
        guard let backLoc = cursor.toTextLocation(in: cs, using: p) else {
            return XCTFail("expected a valid NSTextLocation")
        }
        // The round-trip may not be byte-exact at the very end
        // because `cursor(atStorageIndex:)` for `idx > lastSpan.end`
        // maps to `(lastBlock, lastSpan.length)` and `storageIndex(for:)`
        // maps that back to `lastSpan.location + lastSpan.length` —
        // which equals the storage index of the terminating newline
        // separator, NOT `attributed.length`. Assert the round-tripped
        // location is within the last block's span (inclusive of its
        // trailing position) rather than exactly at docEnd.
        let lastSpan = p.blockSpans.last!
        let expectedIdx = lastSpan.location + lastSpan.length
        XCTAssertEqual(
            cs.offset(from: cs.documentRange.location, to: backLoc),
            expectedIdx
        )
    }

    func test_location_to_cursor_roundtrip_midBlock() {
        let (p, cs) = fixture(twoParagraphMarkdown)
        // Offset 2 lands inside "hello" (block 0).
        guard let loc = cs.location(
            cs.documentRange.location, offsetBy: 2
        ) else { return XCTFail("expected a valid NSTextLocation") }
        guard let cursor = DocumentCursor.from(
            textLocation: loc, in: cs, using: p
        ) else { return XCTFail("expected a valid DocumentCursor") }
        XCTAssertEqual(cursor.blockPath, [0])
        XCTAssertEqual(cursor.inlineOffset, 2)
        guard let backLoc = cursor.toTextLocation(in: cs, using: p) else {
            return XCTFail("expected a valid NSTextLocation")
        }
        XCTAssertEqual(cs.offset(from: loc, to: backLoc), 0)
    }

    // MARK: - DocumentRange ↔ NSRange round-trip

    func test_documentRange_nsRange_roundtrip_emptyAtStart() {
        let (p, _) = fixture(twoParagraphMarkdown)
        let range = DocumentRange(cursor: DocumentCursor(blockIndex: 0, inlineOffset: 0))
        XCTAssertTrue(range.isEmpty)
        let ns = range.toNSRange(in: p)
        XCTAssertEqual(ns, NSRange(location: 0, length: 0))
        guard let back = DocumentRange.fromNSRange(ns, in: p) else {
            return XCTFail("expected a valid DocumentRange")
        }
        XCTAssertTrue(back.isEmpty)
        XCTAssertEqual(back.start.blockPath, [0])
        XCTAssertEqual(back.start.inlineOffset, 0)
    }

    func test_documentRange_nsRange_roundtrip_withinSingleBlock() {
        let (p, _) = fixture(twoParagraphMarkdown)
        let range = DocumentRange(
            start: DocumentCursor(blockIndex: 0, inlineOffset: 1),
            end:   DocumentCursor(blockIndex: 0, inlineOffset: 4)
        )
        let ns = range.toNSRange(in: p)
        XCTAssertEqual(ns, NSRange(location: 1, length: 3))
        guard let back = DocumentRange.fromNSRange(ns, in: p) else {
            return XCTFail("expected a valid DocumentRange")
        }
        XCTAssertEqual(back, range)
    }

    func test_documentRange_nsRange_roundtrip_acrossBlocks() {
        let (p, _) = fixture(twoParagraphMarkdown)
        // Select from offset 3 of block 0 into the last block.
        let lastIdx = p.blockSpans.count - 1
        let range = DocumentRange(
            start: DocumentCursor(blockIndex: 0, inlineOffset: 3),
            end:   DocumentCursor(blockIndex: lastIdx, inlineOffset: 3)
        )
        let ns = range.toNSRange(in: p)
        // Derive expected offsets from the real block spans rather
        // than hard-coded arithmetic — keeps the test robust against
        // renderer changes to inter-block separator width.
        let startIdx = p.blockSpans[0].location + 3
        let endIdx = p.blockSpans[lastIdx].location + 3
        XCTAssertEqual(ns.location, startIdx)
        XCTAssertEqual(ns.length, endIdx - startIdx)
        guard let back = DocumentRange.fromNSRange(ns, in: p) else {
            return XCTFail("expected a valid DocumentRange")
        }
        XCTAssertEqual(back, range)
    }

    func test_documentRange_reversedInput_ordersForward() {
        let (p, _) = fixture(twoParagraphMarkdown)
        // Reverse-oriented: start in a later block, end in an
        // earlier block. Conversion to NSRange must normalize to
        // forward order.
        let lastIdx = p.blockSpans.count - 1
        let range = DocumentRange(
            start: DocumentCursor(blockIndex: lastIdx, inlineOffset: 2),
            end:   DocumentCursor(blockIndex: 0, inlineOffset: 1)
        )
        let ns = range.toNSRange(in: p)
        let earlierIdx = p.blockSpans[0].location + 1
        let laterIdx = p.blockSpans[lastIdx].location + 2
        XCTAssertEqual(ns.location, earlierIdx)
        XCTAssertEqual(ns.length, laterIdx - earlierIdx)
    }

    // MARK: - Negative / edge cases

    func test_fromNSRange_negativeLocation_returnsNil() {
        let (p, _) = fixture("hello\n")
        let bad = NSRange(location: -1, length: 0)
        XCTAssertNil(DocumentRange.fromNSRange(bad, in: p))
    }

    func test_fromNSRange_notFoundSentinel_returnsNil() {
        let (p, _) = fixture("hello\n")
        let notFound = NSRange(location: NSNotFound, length: 0)
        // NSNotFound == Int.max — not negative, so the `>= 0` guard
        // alone would let it through, and the projection's cursor
        // resolution would fall back to the first-block / zero-offset
        // cursor, silently converting "no selection" into "cursor at
        // offset 0". That is semantically wrong: AppKit uses
        // NSNotFound as the "no selection" sentinel. The explicit
        // `range.location != NSNotFound` guard in `fromNSRange`
        // rejects the sentinel so callers can pass it through
        // unchanged.
        XCTAssertNil(
            DocumentRange.fromNSRange(notFound, in: p),
            "NSNotFound sentinel must map to nil so callers can pass it through"
        )
    }

    func test_fromNSRange_outOfBoundsHigh_fallsBackToFirstBlock() {
        let (p, _) = fixture("hello\n")
        // Location past the document end. `cursor(atStorageIndex:)`
        // falls back to block 0 offset 0 for unmappable indices.
        let bad = NSRange(location: 9999, length: 0)
        guard let r = DocumentRange.fromNSRange(bad, in: p) else {
            return XCTFail("expected fallback, not nil")
        }
        XCTAssertEqual(r.start.blockPath, [0])
        XCTAssertEqual(r.start.inlineOffset, 0)
    }

    // MARK: - DocumentRange ↔ NSTextRange

    func test_documentRange_textRange_roundtrip() {
        let (p, cs) = fixture(twoParagraphMarkdown)
        let lastIdx = p.blockSpans.count - 1
        let range = DocumentRange(
            start: DocumentCursor(blockIndex: 0, inlineOffset: 1),
            end:   DocumentCursor(blockIndex: lastIdx, inlineOffset: 2)
        )
        guard let tr = range.toTextRange(in: cs, using: p) else {
            return XCTFail("expected a valid NSTextRange")
        }
        guard let back = DocumentRange.fromTextRange(tr, in: cs, using: p) else {
            return XCTFail("expected a valid DocumentRange")
        }
        XCTAssertEqual(back, range)
    }

    // MARK: - Selection setter no-op-roundtrip (pure, no view needed)

    /// Pins the contract that converting a selection `NSRange` into a
    /// `DocumentRange` and back produces the original `NSRange` for
    /// every selection that represents a single contiguous span inside
    /// the rendered document. This is the contract
    /// `EditTextView.setSelectedRanges` relies on: canonicalizing
    /// through `DocumentRange` does not change the observed selection.
    func test_selection_nsRange_roundtrip_isIdentity_forValidSpans() {
        // Three paragraphs separated by blank lines — this parse
        // shape reliably produces multiple block spans.
        let (p, _) = fixture("hello\n\nworld\n\nthird\n")
        XCTAssertGreaterThanOrEqual(
            p.blockSpans.count, 3,
            "fixture must have at least 3 blocks for this test to be meaningful"
        )
        // Build test cases from the real projection so the round-trip
        // always lands on positions the projection considers valid.
        let b0 = p.blockSpans[0]
        let blast = p.blockSpans.last!
        let cases: [NSRange] = [
            NSRange(location: 0, length: 0),                       // cursor at start
            NSRange(location: b0.location + 3, length: 0),         // cursor inside block 0
            NSRange(location: b0.location, length: b0.length),     // whole block 0
            NSRange(location: blast.location, length: blast.length), // whole last block
            NSRange(location: b0.location + 1,
                    length: blast.location + 2 - (b0.location + 1)), // span crossing all blocks
        ]
        for ns in cases {
            guard let dr = DocumentRange.fromNSRange(ns, in: p) else {
                XCTFail("fromNSRange returned nil for \(ns)")
                continue
            }
            let back = dr.toNSRange(in: p)
            XCTAssertEqual(
                back, ns,
                "round-trip for \(ns) produced \(back)"
            )
        }
    }
}
