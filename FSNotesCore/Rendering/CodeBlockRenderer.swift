//
//  CodeBlockRenderer.swift
//  FSNotesCore
//
//  Renders a Block.codeBlock into an NSAttributedString for display.
//
//  ARCHITECTURAL CONTRACT:
//  - Input: language + raw code content (no fences).
//  - Output: NSAttributedString whose .string contains ONLY the rendered
//    code content. Zero fence characters. Zero `.kern`. Zero clear-color
//    foreground.
//  - Pure function: same input -> byte-equal output, every time.
//  - No hidden syntax. No post-hoc patching. No dependency on prior
//    textStorage state.
//

import Foundation
#if os(OSX)
import AppKit
#else
import UIKit
#endif

public enum CodeBlockRenderer {

    /// Render a code block's content to an attributed string.
    ///
    /// - Parameters:
    ///   - language: fence info-string language identifier (e.g. "python").
    ///     If nil or unrecognized, content is emitted as plain code-font text.
    ///   - content: raw code content (no fences, no trailing newline).
    ///   - codeFont: the monospace font to use for code text.
    /// - Returns: An attributed string containing ONLY `content` (no fences).
    public static func render(
        language: String?,
        content: String,
        codeFont: PlatformFont
    ) -> NSAttributedString {
        // Architectural invariant: the rendered string must contain ONLY
        // the raw code content. It MUST NOT contain fence characters.
        // Downstream tests (NoMarkdownSyntaxInStorage) verify this.
        //
        // Mermaid / math / LaTeX code blocks: emit a single `U+FFFC`
        // attachment character rather than the raw source text. The
        // block's source is carried on the `.renderedBlockSource`
        // attribute (tagged by `DocumentRenderer`) so the fragment
        // (`MermaidLayoutFragment` / `MathLayoutFragment`) can still
        // find it; the attachment reserves one paragraph slot in
        // `NSTextContentStorage` regardless of how many source lines
        // the block contains.
        //
        // Why this matters: `NSTextContentStorage` splits storage into
        // paragraphs on `\n` (Unicode rule). Storing multi-line mermaid
        // source verbatim caused each line to become its own paragraph
        // -> its own `MermaidElement` -> its own `MermaidLayoutFragment`
        // -> its own `BlockRenderer.render(mermaid:)` call with a single
        // line as input. MermaidJS rejects every single-line call
        // because one line isn't a valid diagram. The attachment keeps
        // the block as one paragraph → one element → one fragment →
        // one render.
        //
        // `BlockSourceTextAttachment` is a no-view-provider attachment:
        // the fragment owns all drawing. No TK2 default placeholder
        // paints under the bitmap.
        //
        // Trade-off: Find-in-note cannot match text inside mermaid /
        // math source — the source is on an attribute, not in the
        // paragraph string. Accepted per the 2d follow-up review.
        //
        // Regular code (python, swift, etc.) keeps real `\n` and
        // renders through the syntax highlighter. Per-paragraph element
        // splitting works fine for those because each line renders
        // independently via default text draw.
        switch language?.lowercased() {
        case "mermaid", "math", "latex":
            let attachment = BlockSourceTextAttachment()
            return NSAttributedString(attachment: attachment)
        default:
            break
        }

        if let lang = language {
            let highlighted = runSyntaxHighlighter(code: content, language: lang, codeFont: codeFont)
            return highlighted
        }

        // No language: emit as plain monospaced text.
        let attrs: [NSAttributedString.Key: Any] = [
            .font: codeFont,
            .foregroundColor: PlatformColor.label
        ]
        return NSAttributedString(string: content, attributes: attrs)
    }

    /// Invoke the existing SwiftHighlighter with a themed style.
    /// Uses GitHub Dark/Light theme based on current appearance so
    /// code blocks get proper syntax colors in block-model WYSIWYG mode.
    private static func runSyntaxHighlighter(
        code: String,
        language: String,
        codeFont: PlatformFont
    ) -> NSAttributedString {
        var style = themedStyle()
        style.font = codeFont
        let highlighter = SwiftHighlighter(options: SwiftHighlighter.Options(style: style))
        return highlighter.highlight(code, language: language)
    }

    /// Returns a HighlightStyle matching the user's configured code theme,
    /// so WYSIWYG code blocks use the same colors as source mode.
    private static func themedStyle() -> HighlightStyle {
        let isDark = UserDataService.instance.isDark
        return UserDefaultsManagement.codeTheme.makeStyle(isDark: isDark)
    }
}
