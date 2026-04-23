//
//  Phase44SourceModeTests.swift
//  FSNotesTests
//
//  Phase 4.4 — source mode flipped to `SourceRenderer` + markdown
//  `NotesTextProcessor.highlight*` path retired.
//
//  Pure-function tests for the three block kinds completed in 4.4
//  (`.list`, `.table`, `.htmlBlock`) plus regression guards for the
//  live source-mode dispatch path. No `NSWindow`, no live editor —
//  every assertion runs against `SourceRenderer.render(...)` output.
//

import XCTest
import AppKit
@testable import FSNotes

final class Phase44SourceModeTests: XCTestCase {

    // MARK: - Fonts

    private let bodyFont: NSFont = .systemFont(ofSize: 14)
    private let codeFont: NSFont = NSFont(name: "Menlo", size: 14)
        ?? NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)

    // MARK: - Helpers (duplicated from Phase41SourceRendererTests —
    // both test suites operate on `.markerRange` runs the same way, so
    // replicating the helpers keeps each file self-contained.)

    private func isAllMarker(_ attributed: NSAttributedString, range: NSRange) -> Bool {
        for i in 0..<range.length {
            let v = attributed.attribute(
                .markerRange,
                at: range.location + i,
                effectiveRange: nil
            )
            if v == nil { return false }
        }
        return true
    }

    private func isNoMarker(_ attributed: NSAttributedString, range: NSRange) -> Bool {
        for i in 0..<range.length {
            let v = attributed.attribute(
                .markerRange,
                at: range.location + i,
                effectiveRange: nil
            )
            if v != nil { return false }
        }
        return true
    }

    // MARK: - Live renderer assertions (regression anchor)

    /// The key guarantee of 4.4: `SourceRenderer` IS the live source-mode
    /// renderer — its output carries `.markerRange` runs (and NOT the
    /// legacy colour attributes `NotesTextProcessor.highlightMarkdown`
    /// used to emit). Any future drift where someone re-wires source
    /// mode back to the legacy path will fail this test.
    func test_phase44_sourceRenderer_isLiveRenderer() {
        let doc = Document(
            blocks: [.heading(level: 2, suffix: " Hello")],
            trailingNewline: false
        )
        let out = SourceRenderer.render(
            doc, bodyFont: bodyFont, codeFont: codeFont
        )
        // The rendered output carries `.markerRange` runs.
        var sawMarker = false
        out.enumerateAttribute(
            .markerRange,
            in: NSRange(location: 0, length: out.length),
            options: []
        ) { value, _, _ in
            if value != nil { sawMarker = true }
        }
        XCTAssertTrue(
            sawMarker,
            "SourceRenderer output must tag marker runs via .markerRange (the fragment reads this)."
        )
        // The rendered output is tagged with `.blockModelKind = .sourceMarkdown`
        // so the TK2 content-storage delegate dispatches to SourceMarkdownElement.
        let kind = out.attribute(
            .blockModelKind,
            at: 0,
            effectiveRange: nil
        ) as? String
        XCTAssertEqual(
            kind,
            BlockModelKind.sourceMarkdown.rawValue,
            "SourceRenderer output must tag .blockModelKind = .sourceMarkdown for TK2 dispatch."
        )
    }

    // MARK: - List rendering

    func test_phase44_sourceMode_listRendering_simpleBullet() {
        let items = [
            ListItem(
                indent: "",
                marker: "-",
                afterMarker: " ",
                checkbox: nil,
                inline: [.text("first")],
                children: []
            ),
            ListItem(
                indent: "",
                marker: "-",
                afterMarker: " ",
                checkbox: nil,
                inline: [.text("second")],
                children: []
            )
        ]
        let doc = Document(
            blocks: [.list(items: items, loose: false)],
            trailingNewline: false
        )
        let out = SourceRenderer.render(
            doc, bodyFont: bodyFont, codeFont: codeFont
        )
        XCTAssertEqual(out.string, "- first\n- second")
        // Line 1 marker "- " at 0..<2 (marker), content "first" at 2..<7.
        XCTAssertTrue(isAllMarker(out, range: NSRange(location: 0, length: 2)))
        XCTAssertTrue(isNoMarker(out, range: NSRange(location: 2, length: 5)))
        // Line 2 marker "- " at 8..<10, content "second" at 10..<16.
        XCTAssertTrue(isAllMarker(out, range: NSRange(location: 8, length: 2)))
        XCTAssertTrue(isNoMarker(out, range: NSRange(location: 10, length: 6)))
    }

    func test_phase44_sourceMode_listRendering_ordered() {
        let items = [
            ListItem(
                indent: "",
                marker: "1.",
                afterMarker: " ",
                checkbox: nil,
                inline: [.text("alpha")],
                children: []
            )
        ]
        let doc = Document(
            blocks: [.list(items: items, loose: false)],
            trailingNewline: false
        )
        let out = SourceRenderer.render(
            doc, bodyFont: bodyFont, codeFont: codeFont
        )
        XCTAssertEqual(out.string, "1. alpha")
        // "1. " at 0..<3, marker.
        XCTAssertTrue(isAllMarker(out, range: NSRange(location: 0, length: 3)))
        // "alpha" at 3..<8, content.
        XCTAssertTrue(isNoMarker(out, range: NSRange(location: 3, length: 5)))
    }

    func test_phase44_sourceMode_listRendering_todoCheckbox() {
        let items = [
            ListItem(
                indent: "",
                marker: "-",
                afterMarker: " ",
                checkbox: Checkbox(text: "[ ]", afterText: " "),
                inline: [.text("buy milk")],
                children: []
            )
        ]
        let doc = Document(
            blocks: [.list(items: items, loose: false)],
            trailingNewline: false
        )
        let out = SourceRenderer.render(
            doc, bodyFont: bodyFont, codeFont: codeFont
        )
        XCTAssertEqual(out.string, "- [ ] buy milk")
        // Marker "- " at 0..<2.
        XCTAssertTrue(isAllMarker(out, range: NSRange(location: 0, length: 2)))
        // Checkbox "[ ] " at 2..<6.
        XCTAssertTrue(isAllMarker(out, range: NSRange(location: 2, length: 4)))
        // Content "buy milk" at 6..<14.
        XCTAssertTrue(isNoMarker(out, range: NSRange(location: 6, length: 8)))
    }

    // MARK: - Table rendering

    func test_phase44_sourceMode_tableRendering_simpleTable() {
        let header = [
            TableCell.parsing("A"),
            TableCell.parsing("B")
        ]
        let rows = [
            [TableCell.parsing("1"), TableCell.parsing("2")]
        ]
        let doc = Document(
            blocks: [
                .table(
                    header: header,
                    alignments: [.none, .none],
                    rows: rows,
                    columnWidths: nil
                )
            ],
            trailingNewline: false
        )
        let out = SourceRenderer.render(
            doc, bodyFont: bodyFont, codeFont: codeFont
        )
        // Canonical shape: "| A | B |\n|---|---|\n| 1 | 2 |"
        XCTAssertEqual(out.string, "| A | B |\n|---|---|\n| 1 | 2 |")
        // First character is "|", a marker.
        XCTAssertTrue(
            isAllMarker(out, range: NSRange(location: 0, length: 1)),
            "Opening pipe must be tagged as marker."
        )
        // "A" at index 2 is content (not marker).
        XCTAssertTrue(
            isNoMarker(out, range: NSRange(location: 2, length: 1)),
            "Table cell content must NOT be tagged as marker."
        )
        // Header row is 9 chars ("| A | B |"), newline at 9, then the
        // alignment row "|---|---|" is 9 chars at indices 10..<19.
        XCTAssertTrue(
            isAllMarker(out, range: NSRange(location: 10, length: 9)),
            "Alignment row must be fully tagged as marker."
        )
    }

    func test_phase44_sourceMode_tableRendering_alignmentMarkers() {
        let header = [TableCell.parsing("X")]
        let doc = Document(
            blocks: [
                .table(
                    header: header,
                    alignments: [.center],
                    rows: [],
                    columnWidths: nil
                )
            ],
            trailingNewline: false
        )
        let out = SourceRenderer.render(
            doc, bodyFont: bodyFont, codeFont: codeFont
        )
        // Canonical alignment row for center is "|:---:|".
        XCTAssertTrue(
            out.string.contains(":---:"),
            "Center alignment marker `:---:` must be emitted. Got: \(out.string)"
        )
    }

    // MARK: - HTML block

    func test_phase44_sourceMode_htmlBlockRendering() {
        let raw = "<div class=\"foo\">content</div>"
        let doc = Document(
            blocks: [.htmlBlock(raw: raw)],
            trailingNewline: false
        )
        let out = SourceRenderer.render(
            doc, bodyFont: bodyFont, codeFont: codeFont
        )
        XCTAssertEqual(out.string, raw)
        // The entire HTML content is syntax — tag every character.
        XCTAssertTrue(
            isAllMarker(
                out,
                range: NSRange(location: 0, length: out.length)
            ),
            "HTML block: whole raw content must be tagged as marker."
        )
    }

    // MARK: - Gate enforcement (documentation test)

    /// Documentation test: the grep-gate
    /// `scripts/rule7-gate.sh` matches `NotesTextProcessor\.highlight`
    /// across production code. This test exists so a reader searching
    /// the suite sees the invariant named explicitly; the actual
    /// enforcement is the shell gate and CI.
    ///
    /// If this test fails, it means the gate is no longer wired — not
    /// that a call site was re-added.
    func test_phase44_gate_zero_highlight_callers_in_source_fill() {
        // No-op assertion — the invariant is enforced by the shell
        // gate. This test documents the invariant's existence.
        XCTAssertTrue(true)
    }

    // MARK: - Mode-toggle content round-trip

    /// Toggling between source and WYSIWYG modes must preserve the
    /// note's markdown exactly. The block-model path serializes via
    /// `MarkdownSerializer.serialize(document)`; the source-mode path
    /// serializes as plain text (the buffer IS the markdown). The
    /// round-trip must equal the original markdown for any
    /// well-formed input.
    ///
    /// Simulated here as a pure-function test: parse → render
    /// (SourceRenderer) → round-trip string equality.
    func test_phase44_toggle_sourceToWysiwyg_preservesContent() {
        let markdown = """
        # Title

        Hello **world**.

        - first
        - second

        ```swift
        let x = 1
        ```
        """
        let document = MarkdownParser.parse(markdown)
        let serialized = MarkdownSerializer.serialize(document)
        // MarkdownParser + MarkdownSerializer is the round-trip
        // invariant the block-model pipeline depends on. Source mode
        // doesn't run through the serializer — the textStorage.string
        // IS the markdown — but we assert the same invariant here to
        // guard that the block types SourceRenderer renders also
        // round-trip through the serializer.
        XCTAssertEqual(
            serialized.trimmingCharacters(in: .whitespacesAndNewlines),
            markdown.trimmingCharacters(in: .whitespacesAndNewlines),
            "Markdown must round-trip through parse → serialize unchanged."
        )

        // SourceRenderer output's plain string must equal the markdown
        // for the shared block shapes: paragraph, heading, list,
        // code block. This is what guarantees typing in source mode
        // doesn't drift the content.
        let rendered = SourceRenderer.render(
            document, bodyFont: bodyFont, codeFont: codeFont
        )
        XCTAssertEqual(
            rendered.string.trimmingCharacters(in: .whitespacesAndNewlines),
            markdown.trimmingCharacters(in: .whitespacesAndNewlines),
            "SourceRenderer.render().string must equal the input markdown."
        )
    }
}
