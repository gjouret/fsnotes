//
//  Phase43NonMarkdownRendererTests.swift
//  FSNotesTests
//
//  Phase 4.3 — non-markdown (`.txt` / `.rtf`) TK2 renderer tests.
//
//  Pure-function tests — no `NSWindow`, no live editor. The renderer
//  is a `String` / `Data` → `NSAttributedString` pure function.
//
//  The grep-gate portion ("non-markdown render path doesn't call
//  `NotesTextProcessor.highlight`") is enforced externally via
//  `scripts/rule7-gate.sh` + the repo-level grep documented in
//  REFACTOR_PLAN.md §4.3 step 4. A Swift behavioral test would require
//  method swizzling or a live editor, which defeats the pure-function
//  discipline — the grep gate is the canonical check.
//

import XCTest
import AppKit
@testable import FSNotes

final class Phase43NonMarkdownRendererTests: XCTestCase {

    // MARK: - Fonts

    private let bodyFont: NSFont = .systemFont(ofSize: 14)

    // MARK: - Plain text (.txt)

    func test_phase43_txtRenderer_appliesBodyFont() {
        let input = "Hello, world.\nSecond line."
        let out = NonMarkdownRenderer.render(
            content: input,
            bodyFont: bodyFont
        )

        XCTAssertEqual(out.string, input, "string content must round-trip byte-identically")

        // Every character run must carry the body font.
        let full = NSRange(location: 0, length: out.length)
        var fontRuns = 0
        out.enumerateAttribute(.font, in: full, options: []) { value, _, _ in
            XCTAssertNotNil(value, "every run must carry a .font attribute")
            if let f = value as? NSFont {
                XCTAssertEqual(f.pointSize, bodyFont.pointSize, "font point size must match bodyFont")
            }
            fontRuns += 1
        }
        XCTAssertGreaterThan(fontRuns, 0, "must observe at least one font run")
    }

    func test_phase43_txtRenderer_preservesNewlines() {
        // Mix Unix (\n), Windows (\r\n), and old-Mac (\r) line endings.
        // The renderer must NOT normalize them — the caller already
        // decoded the file bytes.
        let input = "alpha\nbeta\r\ngamma\rdelta"
        let out = NonMarkdownRenderer.render(
            content: input,
            bodyFont: bodyFont
        )

        XCTAssertEqual(out.string, input)
        XCTAssertEqual(out.length, (input as NSString).length)
    }

    func test_phase43_txtRenderer_emptyString_returnsEmptyAttributedString() {
        let out = NonMarkdownRenderer.render(
            content: "",
            bodyFont: bodyFont
        )
        XCTAssertEqual(out.length, 0)
        XCTAssertEqual(out.string, "")
    }

    func test_phase43_txtRenderer_appliesForegroundColor() {
        let out = NonMarkdownRenderer.render(
            content: "plain",
            bodyFont: bodyFont
        )
        let full = NSRange(location: 0, length: out.length)
        out.enumerateAttribute(.foregroundColor, in: full, options: []) { value, _, _ in
            XCTAssertNotNil(value, "every run must carry a foreground color")
        }
    }

    // .rtf tests removed post-review: `NonMarkdownRenderer.renderRTF`
    // was retracted because it was public unused surface (the fill
    // path always collapses .rtf to plain text via Note.getContent()).
    // A future slice re-introduces RTF rendering together with a
    // non-plain load path, size cap, attachment-run filter, and
    // save-round-trip semantics — tests will accompany that slice.

    // MARK: - Routing invariant (documentation-driven)

    /// The grep gate lives in `scripts/rule7-gate.sh` and in the
    /// REFACTOR_PLAN.md §4.3 step 4 shell invariant. This Swift test
    /// documents WHAT the gate enforces, so a reviewer who doesn't run
    /// the shell gate is still alerted to the invariant.
    ///
    /// Manual verification step (run from repo root):
    /// ```
    /// grep -rn "NotesTextProcessor.highlight" FSNotes/ FSNotesCore/ \
    ///   | grep -v Tests/ | grep -vE '// |//\s*'
    /// ```
    /// Expected hits live ONLY in the markdown source-mode path; no
    /// hit may reference the non-markdown fill branch (the `else`
    /// branch of `EditTextView+NoteState.fill` / the `nonMarkdownActive`
    /// guard in `TextStorageProcessor.process`).
    func test_phase43_txt_doesNotRouteThroughNotesTextProcessor_documentationOnly() {
        // No-op — this test's body documents the invariant. The actual
        // gate is the shell grep above and `scripts/rule7-gate.sh`.
        // Phase 4.4 tightens the grep to require zero hits anywhere.
        XCTAssertTrue(true)
    }
}
