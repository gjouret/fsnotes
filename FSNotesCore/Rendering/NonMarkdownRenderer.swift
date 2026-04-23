//
//  NonMarkdownRenderer.swift
//  FSNotesCore
//
//  Phase 4.3 — non-markdown (.txt) TK2 render path.
//
//  Sibling of `DocumentRenderer` (markdown WYSIWYG) and `SourceRenderer`
//  (markdown source mode, dormant until 4.4). Non-markdown notes do NOT
//  participate in the block model:
//    * `.txt`  — plain text, wrap the string in an `NSAttributedString`
//                carrying `.font = bodyFont` + `.foregroundColor`.
//
//  Rule 7 conscience:
//    * No markdown parsing, no `InlineRenderer`, no block model.
//    * No calls to `NotesTextProcessor.highlight*` — those are the
//      markdown path's business, not ours. Phase 4.3's grep gate
//      enforces this.
//    * Pure function on value types (`String` / font / theme).
//      Fully unit-testable without `NSWindow` or live editor.
//
//  `.rtf` — DEFERRED. The macOS fill path reads `.rtf` notes through
//    `Note.getContent()` which forces `.documentType = .plain`, so RTF
//    attribute runs are already stripped by the time non-markdown render
//    sees the content. A proper `.rtf` fidelity slice requires (a) a
//    separate load path that hands raw `Data` to the renderer, (b) a
//    size cap + attachment-run filter (RTF parsing has historic CVE
//    surface, e.g. CVE-2019-8761), (c) save-round-trip semantics for
//    RTF edits. All three are their own design decisions tracked for a
//    future slice. Today `.rtf` notes continue to render as plain text
//    via the `.txt` branch — zero behavioral regression vs. pre-4.3,
//    which is also what they got before.
//

import Foundation
#if os(OSX)
import AppKit
#else
import UIKit
#endif

public enum NonMarkdownRenderer {

    // MARK: - Plain text

    /// Render plain text content (`.txt`) with the body font + theme
    /// foreground applied uniformly.
    ///
    /// - Parameter content: the raw file contents as a string. Newlines
    ///   (`\n`, `\r\n`, `\r`) are preserved byte-identically — no
    ///   normalization. The caller already decoded the file bytes.
    /// - Parameter bodyFont: the font to apply to every character.
    ///   Callers pass `UserDefaultsManagement.noteFont` (which in Phase
    ///   7.5.c is a Theme proxy).
    /// - Parameter theme: active theme. Reserved for future chrome
    ///   plumbing; currently only the default body foreground is read
    ///   (via `PlatformColor.label` — matches `ParagraphRenderer`).
    /// - Returns: `NSAttributedString` with `.font` + `.foregroundColor`
    ///   covering the full length. Empty string returns an empty
    ///   attributed string (no attribute runs).
    public static func render(
        content: String,
        bodyFont: PlatformFont,
        theme: Theme = .shared
    ) -> NSAttributedString {
        _ = theme  // reserved — default foreground is PlatformColor.label
        if content.isEmpty {
            return NSAttributedString()
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: bodyFont,
            .foregroundColor: PlatformColor.label
        ]
        return NSAttributedString(string: content, attributes: attrs)
    }

    // `renderRTF(data:bodyFont:theme:)` was removed post-review. The
    // earlier implementation parsed raw RTF via
    // `NSAttributedString(rtf:documentAttributes:)` and backfilled
    // fallback font/color on unstyled runs. It was public but had zero
    // production callers — the fill path always collapsed `.rtf` notes
    // to plain text via `Note.getContent()` before the renderer saw
    // them, so the RTF-fidelity contract documented above was
    // aspirational. Shipping the surface unwired + unaudited for RTF
    // parsing CVE exposure (e.g. CVE-2019-8761) is a foot-gun. A
    // future slice re-introduces the function together with:
    //   (a) a non-plain load path that hands raw Data here,
    //   (b) a size cap + attachment-run filter,
    //   (c) save-round-trip semantics for RTF edits.
}
