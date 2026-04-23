//
//  NonMarkdownRenderer.swift
//  FSNotesCore
//
//  Phase 4.3 — non-markdown (.txt / .rtf) TK2 render path.
//
//  Sibling of `DocumentRenderer` (markdown WYSIWYG) and `SourceRenderer`
//  (markdown source mode, dormant until 4.4). Non-markdown notes do NOT
//  participate in the block model:
//    * `.txt`  — plain text, wrap the string in an `NSAttributedString`
//                carrying `.font = bodyFont` + `.foregroundColor`.
//    * `.rtf`  — the file already encodes its own attributes; parse via
//                `NSAttributedString(rtf:documentAttributes:)`, then fill
//                in `.font = bodyFont` only on runs that don't already
//                carry one. Existing bold / italic / color runs are left
//                as-is (so user styling round-trips).
//
//  Rule 7 conscience:
//    * No markdown parsing, no `InlineRenderer`, no block model.
//    * No calls to `NotesTextProcessor.highlight*` — those are the
//      markdown path's business, not ours. Phase 4.3's grep gate
//      enforces this.
//    * Pure function on value types (`String` / `Data` / font / theme).
//      Fully unit-testable without `NSWindow` or live editor.
//
//  Design note on String vs Data:
//    * The macOS fill path (`EditTextView+NoteState.fill(note:)`) reads
//      non-markdown notes into `Note.content: NSMutableAttributedString`
//      via `getContent()`, which wraps `NSMutableAttributedString(url:
//      options:)` with `.documentType = .plain`. So for `.txt` the
//      content is already a string; for `.rtf` the current code path
//      silently dropped RTF attributes by forcing `.plain` — this
//      renderer fixes that by exposing `renderRTF(data:...)` that takes
//      the raw bytes and parses as RTF when the caller knows the file
//      is rich text.
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

    // MARK: - Rich text

    /// Render rich text content (`.rtf`) preserving its native styling,
    /// then normalize any un-styled runs to `bodyFont` + theme foreground
    /// so new text typed into the editor inherits the editor's body font
    /// rather than whatever default RTF chose.
    ///
    /// - Parameter data: raw bytes of the `.rtf` file.
    /// - Parameter bodyFont: fallback font applied only to runs that
    ///   don't already have a `.font` attribute. RTF-encoded fonts are
    ///   preserved as-is.
    /// - Parameter theme: active theme. Reserved (see `render(content:)`).
    /// - Returns:
    ///     * On success: `NSAttributedString` from the RTF data, with
    ///       fallback attributes applied where absent.
    ///     * On empty input: empty `NSAttributedString`.
    ///     * On malformed data: empty `NSAttributedString` (documented
    ///       behavior — `NSAttributedString(rtf:)` failure is non-fatal
    ///       and maps to an empty render so the editor can still open
    ///       the note for the user to repair).
    public static func renderRTF(
        data: Data,
        bodyFont: PlatformFont,
        theme: Theme = .shared
    ) -> NSAttributedString {
        _ = theme  // reserved
        if data.isEmpty {
            return NSAttributedString()
        }
        guard let parsed = NSMutableAttributedString(
            rtf: data,
            documentAttributes: nil
        ) else {
            // Malformed data — documented contract: return empty,
            // don't throw. The caller (fill path) can then show the
            // user an empty editor rather than crashing.
            return NSAttributedString()
        }

        // Backfill body font + foreground on runs that lack them. Don't
        // overwrite existing RTF attributes — that would destroy the
        // user's styling.
        let full = NSRange(location: 0, length: parsed.length)
        if full.length > 0 {
            parsed.enumerateAttribute(.font, in: full, options: []) { value, range, _ in
                if value == nil {
                    parsed.addAttribute(.font, value: bodyFont, range: range)
                }
            }
            parsed.enumerateAttribute(.foregroundColor, in: full, options: []) { value, range, _ in
                if value == nil {
                    parsed.addAttribute(
                        .foregroundColor,
                        value: PlatformColor.label,
                        range: range
                    )
                }
            }
        }

        return parsed
    }
}
