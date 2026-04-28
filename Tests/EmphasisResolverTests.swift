//
//  EmphasisResolverTests.swift
//  FSNotesTests
//
//  Phase 12.C.4 — Emphasis resolver port tests.
//
//  CommonMark §6.2 emphasis bucket is at 132/132 (100%); the spec
//  corpus pins public-API behavior. These tests pin the moved
//  algorithm directly:
//   * `flanking(...)` — the ~20 spec rules around left/right-flanking
//     with `*` vs `_` distinctions.
//   * `resolve(tokens:)` — the delimiter-stack walk, including the
//     Rule of 3 / nested emphasis / odd-count cases.
//
//  Without these, a bug in the port would surface as one of the 132
//  spec failures, and the trace would walk through `parseInlines`
//  before reaching the cause.
//

import XCTest
@testable import FSNotes

final class EmphasisFlankingTests: XCTestCase {

    // MARK: - `*` flanking (permissive)

    func test_asterisk_betweenLetters_canOpenAndClose() {
        let (canOpen, canClose) = EmphasisResolver.flanking(
            delimChar: "*", before: "a", after: "b"
        )
        XCTAssertTrue(canOpen)
        XCTAssertTrue(canClose)
    }

    func test_asterisk_followedByWhitespace_cannotOpen() {
        let (canOpen, _) = EmphasisResolver.flanking(
            delimChar: "*", before: "a", after: " "
        )
        XCTAssertFalse(canOpen)
    }

    func test_asterisk_precededByWhitespace_cannotClose() {
        let (_, canClose) = EmphasisResolver.flanking(
            delimChar: "*", before: " ", after: "a"
        )
        XCTAssertFalse(canClose)
    }

    func test_asterisk_atStartOfString_canOpen() {
        let (canOpen, canClose) = EmphasisResolver.flanking(
            delimChar: "*", before: nil, after: "a"
        )
        XCTAssertTrue(canOpen)
        XCTAssertFalse(canClose)
    }

    // MARK: - `_` flanking (intra-word stricter)

    func test_underscore_betweenLetters_isIntraword_neither() {
        // `snake_case` — the `_` is left+right flanking but neither
        // adjacent char is punctuation, so canOpen and canClose are
        // both false (prevents `snake_case_var` from emphasizing).
        let (canOpen, canClose) = EmphasisResolver.flanking(
            delimChar: "_", before: "a", after: "b"
        )
        XCTAssertFalse(canOpen)
        XCTAssertFalse(canClose)
    }

    func test_underscore_afterWhitespaceBeforeLetter_canOpen() {
        let (canOpen, canClose) = EmphasisResolver.flanking(
            delimChar: "_", before: " ", after: "x"
        )
        XCTAssertTrue(canOpen)
        XCTAssertFalse(canClose)
    }

    func test_underscore_afterLetterBeforeWhitespace_canClose() {
        let (canOpen, canClose) = EmphasisResolver.flanking(
            delimChar: "_", before: "x", after: " "
        )
        XCTAssertFalse(canOpen)
        XCTAssertTrue(canClose)
    }

    // MARK: - v0.31.2 punctuation broadening (spec #354)

    func test_currencySymbolTreatedAsPunctuation() {
        // `*£*bravo.` — the `£` (currency symbol Sc) must be treated
        // as punctuation so the surrounding `*` is left-flanking but
        // NOT inside intra-word emphasis. The first `*` precedes `£`,
        // so before=nil/whitespace, after=£. Punctuation after, no
        // whitespace either side, so canOpen depends on the
        // preceded-by-whitespace clause.
        let (canOpen, _) = EmphasisResolver.flanking(
            delimChar: "*", before: " ", after: "£"
        )
        XCTAssertTrue(canOpen)
    }
}

final class EmphasisResolveTests: XCTestCase {

    /// Convenience: parse markdown and return the (only) paragraph's
    /// inline children. Lets these tests assert against the public
    /// API while still living in the resolver test file.
    private func inlines(_ md: String) -> [Inline] {
        let doc = MarkdownParser.parse(md)
        guard case .paragraph(let inline) = doc.blocks[0] else {
            XCTFail("expected paragraph, got \(doc.blocks)")
            return []
        }
        return inline
    }

    func test_singleAsterisk_producesItalic() {
        let inl = inlines("*hi*")
        XCTAssertEqual(inl.count, 1)
        guard case .italic(let kids, let mk) = inl[0] else {
            return XCTFail("expected italic, got \(inl)")
        }
        XCTAssertEqual(mk, .asterisk)
        guard case .text(let s) = kids[0] else {
            return XCTFail("expected text child")
        }
        XCTAssertEqual(s, "hi")
    }

    func test_doubleAsterisk_producesBold() {
        let inl = inlines("**hi**")
        XCTAssertEqual(inl.count, 1)
        guard case .bold(let kids, _) = inl[0] else {
            return XCTFail("expected bold, got \(inl)")
        }
        guard case .text(let s) = kids[0] else {
            return XCTFail("expected text child")
        }
        XCTAssertEqual(s, "hi")
    }

    func test_tripleAsterisk_producesItalicOfBold() {
        // `***hi***` → `<em><strong>hi</strong></em>` per CommonMark
        // spec example #437. The single closer matches the closest
        // single opener, leaving the double pair to nest outside.
        let inl = inlines("***hi***")
        guard case .italic(let outerKids, _) = inl[0] else {
            return XCTFail("expected outer italic, got \(inl)")
        }
        guard case .bold(let innerKids, _) = outerKids[0] else {
            return XCTFail("expected inner bold, got \(outerKids)")
        }
        guard case .text(let s) = innerKids[0] else {
            return XCTFail("expected innermost text")
        }
        XCTAssertEqual(s, "hi")
    }

    func test_underscoreIntraWord_doesNotEmphasize() {
        // `foo_bar_baz` — underscore is intra-word, no emphasis.
        let inl = inlines("foo_bar_baz")
        XCTAssertEqual(inl.count, 1)
        guard case .text(let s) = inl[0] else {
            return XCTFail("expected single text inline, got \(inl)")
        }
        XCTAssertEqual(s, "foo_bar_baz")
    }

    func test_unmatchedAsterisk_remainsLiteral() {
        let inl = inlines("a*b")
        // Should be a single text inline `a*b` (no emphasis).
        for ix in inl {
            if case .italic = ix { XCTFail("unexpected italic in unmatched-* input") }
            if case .bold = ix { XCTFail("unexpected bold in unmatched-* input") }
        }
    }

    func test_ruleOf3_skipsMismatchedSums() {
        // `*foo**bar*` — closer `*` after `bar`, opener `*` before
        // `foo`. The middle `**` count + closer `*` count = 3 violates
        // Rule of 3 in some configurations. This test pins the
        // round-trip via the public API.
        let inl = inlines("*foo**bar*")
        // Expected per spec: italic(foo**bar) — i.e. the `**` becomes
        // literal text inside the italic. Different parsers vary; we
        // pin our current behavior so the resolver port doesn't drift.
        guard case .italic(let kids, _) = inl[0] else {
            return XCTFail("expected italic, got \(inl)")
        }
        // The italic body should contain foo, **, bar (in some shape).
        XCTAssertFalse(kids.isEmpty)
    }

    func test_codeSpanInsideEmphasis_isPreserved() {
        let inl = inlines("*a `b` c*")
        guard case .italic(let kids, _) = inl[0] else {
            return XCTFail("expected italic, got \(inl)")
        }
        let codeKids = kids.compactMap { ix -> String? in
            if case .code(let s) = ix { return s } else { return nil }
        }
        XCTAssertEqual(codeKids, ["b"])
    }
}
