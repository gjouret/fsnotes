//
//  EditorSnapshotTests.swift
//  FSNotesTests
//
//  Meta-tests for `EditorSnapshot`: the emitter is deterministic,
//  the matcher honours its equivalence rules (whitespace, `*`
//  wildcards, `frame≈` tolerance), and selectors resolve to the
//  expected block/span.
//
//  These tests verify the SNAPSHOT layer itself — they must pass
//  regardless of whether the underlying UI bugs captured in
//  `UIBugRegressionTests` are fixed. A broken snapshot emitter
//  produces useless regression tests.
//

import XCTest
@testable import FSNotes

final class EditorSnapshotTests: XCTestCase {

    // MARK: - Emission

    func test_emit_includesEditorHeader() {
        let h = EditorHarness(markdown: "Hello")
        defer { h.teardown() }
        let snap = h.snapshot()
        XCTAssertTrue(
            snap.raw.hasPrefix("(editor len="),
            "Expected (editor len=... header. Got:\n\(snap.raw)"
        )
        XCTAssertTrue(
            snap.raw.contains("selection="),
            "Expected selection= in snapshot."
        )
    }

    func test_emit_emitsOneBlockFormPerBlock() {
        let h = EditorHarness(markdown: "# H1\n\nHello\n\n```\ncode\n```")
        defer { h.teardown() }
        let snap = h.snapshot()
        // Block indices include .blankLine separators, so we
        // match by kind presence rather than by index.
        XCTAssertTrue(snap.contains("kind=heading"),
                      "Expected heading block. Got:\n\(snap.raw)")
        XCTAssertTrue(snap.contains("kind=paragraph"),
                      "Expected paragraph block. Got:\n\(snap.raw)")
        XCTAssertTrue(snap.contains("kind=codeBlock"),
                      "Expected codeBlock block. Got:\n\(snap.raw)")
    }

    func test_emit_includesInlineTreeForParagraph() {
        let h = EditorHarness(markdown: "Hello, **world**!")
        defer { h.teardown() }
        let snap = h.snapshot()
        XCTAssertTrue(
            snap.contains("(inline "),
            "Expected inline form. Got:\n\(snap.raw)"
        )
        XCTAssertTrue(
            snap.contains("(bold "),
            "Expected bold run in inline form. Got:\n\(snap.raw)"
        )
    }

    func test_emit_codeBlockRecordsLanguage() {
        let h = EditorHarness(markdown: "```swift\nlet x = 1\n```")
        defer { h.teardown() }
        let snap = h.snapshot()
        XCTAssertTrue(
            snap.contains("language=swift"),
            "Expected language=swift on code block. Got:\n\(snap.raw)"
        )
    }

    func test_emit_headingRecordsLevel() {
        let h = EditorHarness(markdown: "## Sub")
        defer { h.teardown() }
        let snap = h.snapshot()
        XCTAssertTrue(
            snap.contains("level=2"),
            "Expected level=2 on heading. Got:\n\(snap.raw)"
        )
    }

    func test_emit_isDeterministicAcrossCalls() {
        let h = EditorHarness(markdown: "# Header\n\nPara.")
        defer { h.teardown() }
        let a = h.snapshot().raw
        let b = h.snapshot().raw
        XCTAssertEqual(a, b, "Two calls to snapshot() produced different output.")
    }

    func test_emit_tableIncludesCellForms() {
        let h = EditorHarness(markdown: "| a | b |\n|---|---|\n| 1 | 2 |")
        defer { h.teardown() }
        let snap = h.snapshot()
        XCTAssertTrue(
            snap.contains("kind=table"),
            "Expected table block. Got:\n\(snap.raw)"
        )
        XCTAssertTrue(
            snap.contains("(cell r=-1 c=0"),
            "Expected header cell r=-1 c=0. Got:\n\(snap.raw)"
        )
        XCTAssertTrue(
            snap.contains("(cell r=0 c=0"),
            "Expected body cell r=0 c=0. Got:\n\(snap.raw)"
        )
    }

    // MARK: - Matcher equivalence rules

    func test_matcher_whitespaceCollapses() {
        let raw = "(editor len=5 selection=0..0\n  (block 0 kind=paragraph span=0..5))"
        let snap = EditorSnapshot(raw: raw)
        XCTAssertTrue(snap.contains("(block 0 kind=paragraph span=0..5)"))
        XCTAssertTrue(snap.contains("(block 0   kind=paragraph   span=0..5)"),
                      "Runs of spaces should collapse to one.")
    }

    func test_matcher_wildcardMatchesToken() {
        let raw = "(editor len=5 selection=0..0\n  (block 0 kind=paragraph span=0..5))"
        let snap = EditorSnapshot(raw: raw)
        XCTAssertTrue(snap.contains("(block 0 kind=* span=0..5)"))
        XCTAssertTrue(snap.contains("(block 0 kind=paragraph span=*..*)"))
    }

    func test_matcher_frameApproxToleratesOnePoint() {
        let raw = "(block 0 kind=paragraph span=0..5\n  (overlay class=Foo visible=true frame≈10,20,100,50))"
        let snap = EditorSnapshot(raw: raw)
        // Exact match.
        XCTAssertTrue(
            snap.contains("frame≈10,20,100,50"),
            "Exact frame should match."
        )
        // ±1 tolerance per coord.
        XCTAssertTrue(
            snap.contains("frame≈11,21,99,50"),
            "±1 tolerance should match."
        )
        // Out of tolerance — should NOT match.
        XCTAssertFalse(
            snap.contains("frame≈13,20,100,50"),
            "3-pt offset should not match."
        )
    }

    func test_matcher_frameApproxAcceptsWildcardSlots() {
        let raw = "(overlay class=Foo frame≈0,50,500,120)"
        let snap = EditorSnapshot(raw: raw)
        XCTAssertTrue(
            snap.contains("frame≈*,*,500,120"),
            "Wildcard origin with exact size should match."
        )
    }

    // MARK: - Selectors

    func test_select_resolvesBlockForm() {
        let h = EditorHarness(markdown: "# Header\n\nPara")
        defer { h.teardown() }
        let snap = h.snapshot()
        // `block[0]` is always the first block — the heading.
        guard let form = snap.select(path: "block[0]") else {
            XCTFail("Expected block[0] to resolve.\n\(snap.raw)")
            return
        }
        XCTAssertTrue(
            form.contains("kind=heading"),
            "Expected block[0] form to contain heading. Got: \(form)"
        )
    }

    func test_assertSelectionInside_passesWhenInside() {
        let h = EditorHarness(markdown: "Hello world")
        defer { h.teardown() }
        h.moveCursor(to: 3)
        let snap = h.snapshot()
        snap.assertSelectionInside("block[0]")
        // No failure means pass.
    }

    // MARK: - Fragment dispatch

    func test_emit_headingFragmentClass() {
        let h = EditorHarness(markdown: "# Header")
        defer { h.teardown() }
        let snap = h.snapshot()
        // Headings dispatch to HeadingLayoutFragment per
        // BlockModelLayoutManagerDelegate.
        XCTAssertTrue(
            snap.contains("class=HeadingLayoutFragment"),
            "Expected HeadingLayoutFragment. Got:\n\(snap.raw)"
        )
    }

    func test_emit_codeBlockFragmentClass() {
        let h = EditorHarness(markdown: "```\nx\n```")
        defer { h.teardown() }
        let snap = h.snapshot()
        XCTAssertTrue(
            snap.contains("class=CodeBlockLayoutFragment"),
            "Expected CodeBlockLayoutFragment. Got:\n\(snap.raw)"
        )
    }
}
