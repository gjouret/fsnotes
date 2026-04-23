//
//  Phase41SourceRendererTests.swift
//  FSNotesTests
//
//  Phase 4.1 — `SourceRenderer` + `.markerRange` skeleton tests.
//
//  Pure-function tests — no `NSWindow`, no live editor. The renderer
//  is a `Document` → `NSAttributedString` pure function; the fragment
//  tests exercise only its instantiation and a crash-free draw on a
//  trivial attributed string (the fragment is dormant until Phase 4.4
//  wires it into live source-mode layout).
//

import XCTest
import AppKit
@testable import FSNotes

final class Phase41SourceRendererTests: XCTestCase {

    // MARK: - Fonts

    private let bodyFont: NSFont = .systemFont(ofSize: 14)
    private let codeFont: NSFont = NSFont(name: "Menlo", size: 14)
        ?? NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)

    // MARK: - Helpers

    /// Return every contiguous range of `attributed` that carries
    /// `.markerRange`, plus the string that covers those ranges as a
    /// concatenation.
    private func markerRanges(
        in attributed: NSAttributedString
    ) -> [NSRange] {
        var ranges: [NSRange] = []
        let full = NSRange(location: 0, length: attributed.length)
        attributed.enumerateAttribute(
            .markerRange, in: full, options: []
        ) { value, range, _ in
            if value != nil {
                ranges.append(range)
            }
        }
        return ranges
    }

    /// True if `attributed` has `.markerRange` on EVERY character of
    /// `range`.
    private func isAllMarker(
        _ attributed: NSAttributedString,
        range: NSRange
    ) -> Bool {
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

    /// True if `attributed` has NO `.markerRange` on any character of
    /// `range`.
    private func isNoMarker(
        _ attributed: NSAttributedString,
        range: NSRange
    ) -> Bool {
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

    // MARK: - Feature flag default — retired
    //
    // Phase 4.4 deleted `FeatureFlag.useSourceRendererV2`; source mode
    // unconditionally uses `SourceRenderer`. The 4.1 dormant-flag test
    // is no longer meaningful and has been removed.

    // MARK: - Heading

    func test_phase41_heading_rendersWithHashMarker() {
        let doc = Document(
            blocks: [.heading(level: 1, suffix: " Hello")],
            trailingNewline: false
        )
        let out = SourceRenderer.render(
            doc, bodyFont: bodyFont, codeFont: codeFont
        )

        XCTAssertEqual(
            out.string,
            "# Hello",
            "H1 source-mode output should include the `#` marker + space + content."
        )

        // The `#` (index 0) + the space (index 1) are marker.
        XCTAssertTrue(
            isAllMarker(out, range: NSRange(location: 0, length: 2)),
            "The `# ` prefix must be fully tagged as `.markerRange`."
        )
    }

    func test_phase41_heading_markerRangeNotSetOnContent() {
        let doc = Document(
            blocks: [.heading(level: 1, suffix: " Hello")],
            trailingNewline: false
        )
        let out = SourceRenderer.render(
            doc, bodyFont: bodyFont, codeFont: codeFont
        )
        // "Hello" starts at index 2, length 5.
        let contentRange = NSRange(location: 2, length: 5)
        XCTAssertEqual(
            (out.string as NSString).substring(with: contentRange),
            "Hello"
        )
        XCTAssertTrue(
            isNoMarker(out, range: contentRange),
            "Heading CONTENT must NOT be tagged as marker."
        )
    }

    // MARK: - Code block

    func test_phase41_codeBlock_rendersWithFenceMarkers() {
        let fence = FenceStyle(character: .backtick, length: 3, infoRaw: "swift")
        let doc = Document(
            blocks: [
                .codeBlock(
                    language: "swift",
                    content: "let x = 1",
                    fence: fence
                )
            ],
            trailingNewline: false
        )
        let out = SourceRenderer.render(
            doc, bodyFont: bodyFont, codeFont: codeFont
        )

        XCTAssertEqual(
            out.string,
            "```swift\nlet x = 1\n```",
            "Code block source output must reproduce fences + info + content."
        )

        // Opening fence "```swift" = indices 0..<8, all marker.
        let openFence = NSRange(location: 0, length: 8)
        XCTAssertTrue(
            isAllMarker(out, range: openFence),
            "Opening fence + info string must be tagged as marker."
        )

        // Code content "let x = 1" = indices 9..<18, no marker.
        let content = NSRange(location: 9, length: 9)
        XCTAssertEqual(
            (out.string as NSString).substring(with: content),
            "let x = 1"
        )
        XCTAssertTrue(
            isNoMarker(out, range: content),
            "Code block CONTENT must NOT be tagged as marker."
        )

        // Closing fence "```" = indices 19..<22, all marker.
        let closeFence = NSRange(location: 19, length: 3)
        XCTAssertTrue(
            isAllMarker(out, range: closeFence),
            "Closing fence must be tagged as marker."
        )
    }

    // MARK: - Blockquote

    func test_phase41_blockquote_rendersWithGtMarkers() {
        let line1 = BlockquoteLine(prefix: "> ", inline: [.text("hello")])
        let line2 = BlockquoteLine(prefix: "> ", inline: [.text("world")])
        let doc = Document(
            blocks: [.blockquote(lines: [line1, line2])],
            trailingNewline: false
        )
        let out = SourceRenderer.render(
            doc, bodyFont: bodyFont, codeFont: codeFont
        )

        XCTAssertEqual(
            out.string,
            "> hello\n> world",
            "Blockquote source output must reproduce `> ` prefixes per line."
        )

        // Line 1 prefix "> " at indices 0..<2, all marker.
        XCTAssertTrue(
            isAllMarker(out, range: NSRange(location: 0, length: 2)),
            "Line 1 `> ` prefix must be tagged as marker."
        )
        // Line 2 prefix "> " at indices 8..<10, all marker.
        // ("> hello" = 7 chars, then "\n" at 7, prefix starts at 8)
        XCTAssertTrue(
            isAllMarker(out, range: NSRange(location: 8, length: 2)),
            "Line 2 `> ` prefix must be tagged as marker."
        )
        // Content "hello" at indices 2..<7 carries NO marker.
        XCTAssertTrue(
            isNoMarker(out, range: NSRange(location: 2, length: 5)),
            "Blockquote CONTENT must NOT be tagged as marker."
        )
    }

    // MARK: - Horizontal rule

    func test_phase41_hr_rendersAsTaggedMarkerLine() {
        let doc = Document(
            blocks: [.horizontalRule(character: "-", length: 3)],
            trailingNewline: false
        )
        let out = SourceRenderer.render(
            doc, bodyFont: bodyFont, codeFont: codeFont
        )
        XCTAssertEqual(out.string, "---")
        XCTAssertTrue(
            isAllMarker(
                out,
                range: NSRange(location: 0, length: out.length)
            ),
            "Horizontal rule: whole line must be tagged as marker."
        )
    }

    // MARK: - List rendering (Phase 4.4)

    func test_phase44_list_rendersMarkerTaggedBullets() {
        let item = ListItem(
            indent: "",
            marker: "-",
            afterMarker: " ",
            checkbox: nil,
            inline: [.text("one")],
            children: []
        )
        let doc = Document(
            blocks: [.list(items: [item], loose: false)],
            trailingNewline: false
        )
        let out = SourceRenderer.render(
            doc, bodyFont: bodyFont, codeFont: codeFont
        )
        XCTAssertEqual(
            out.string,
            "- one",
            "List source output must reproduce the dash marker + space + content."
        )
        // "- " at indices 0..<2, all marker.
        XCTAssertTrue(
            isAllMarker(out, range: NSRange(location: 0, length: 2)),
            "List marker `- ` must be tagged as marker."
        )
        // "one" at indices 2..<5, content.
        XCTAssertTrue(
            isNoMarker(out, range: NSRange(location: 2, length: 3)),
            "List content must NOT be tagged as marker."
        )
    }

    // MARK: - Paragraph with inline markers

    func test_phase41_paragraph_reinjectsBoldMarkers() {
        // The parser consumes `**bold**` and produces `.bold([.text("bold")])`.
        // Source mode must re-emit those markers and tag them.
        let inline: [Inline] = [
            .text("say "),
            .bold([.text("hi")], marker: .asterisk),
            .text("!")
        ]
        let doc = Document(
            blocks: [.paragraph(inline: inline)],
            trailingNewline: false
        )
        let out = SourceRenderer.render(
            doc, bodyFont: bodyFont, codeFont: codeFont
        )
        XCTAssertEqual(out.string, "say **hi**!")

        // "**" opener at indices 4..<6, marker.
        XCTAssertTrue(
            isAllMarker(out, range: NSRange(location: 4, length: 2)),
            "Bold opening `**` must be tagged as marker."
        )
        // "hi" content at indices 6..<8, NOT marker.
        XCTAssertTrue(
            isNoMarker(out, range: NSRange(location: 6, length: 2)),
            "Bold content must NOT be tagged as marker."
        )
        // "**" closer at indices 8..<10, marker.
        XCTAssertTrue(
            isAllMarker(out, range: NSRange(location: 8, length: 2)),
            "Bold closing `**` must be tagged as marker."
        )
    }

    // MARK: - Fragment smoke test

    func test_phase41_fragment_instantiatesWithoutCrash() {
        // Build a trivial attributed string that carries a marker run
        // plus a content run, then instantiate the fragment on a
        // containing paragraph element. The fragment is dormant in
        // Phase 4.1 — no live dispatch path reaches it — so the smoke
        // test exercises only the construction surface:
        //   * Can we build a `SourceLayoutFragment` over a paragraph
        //     that carries `.markerRange` runs.
        //   * Does the fragment read the text element we gave it.
        //
        // A `draw(at:in:)` smoke test on an unlaid-out fragment would
        // need a full `NSTextContentManager` + `NSTextLayoutManager`
        // setup; that's out of scope for this additive dormant slice.
        // Phase 4.4 lands the live dispatch path and owns the
        // draw-integration test.
        let attrs: [NSAttributedString.Key: Any] = [
            .font: bodyFont,
            .markerRange: NSNull()
        ]
        let marker = NSAttributedString(string: "#", attributes: attrs)
        let content = NSAttributedString(
            string: " Hello",
            attributes: [.font: bodyFont]
        )
        let combined = NSMutableAttributedString()
        combined.append(marker)
        combined.append(content)

        let paragraph = NSTextParagraph(attributedString: combined)
        let fragment = SourceLayoutFragment(
            textElement: paragraph,
            range: paragraph.elementRange
        )

        XCTAssertNotNil(fragment)
        XCTAssertTrue(
            fragment.textElement === paragraph,
            "Fragment must hold a reference to the paragraph it was constructed with."
        )

        // Sanity-check the marker-color accessor resolves without
        // crashing in the test-host appearance context.
        let color = SourceLayoutFragment.markerColor
        XCTAssertNotNil(color)
    }
}
