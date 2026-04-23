//
//  HeadingRenderer.swift
//  FSNotesCore
//
//  Renders a Block.heading into an NSAttributedString for display.
//
//  ARCHITECTURAL CONTRACT:
//  - Input: heading level (1–6) + raw suffix (everything after the `#`
//    markers in the source line).
//  - Output: NSAttributedString containing ONLY the displayed heading
//    text (suffix trimmed of surrounding whitespace). Zero `#`
//    characters. Zero `.kern`. Zero clear-color foreground.
//  - Pure function: same input → byte-equal output.
//

import Foundation
#if os(OSX)
import AppKit
#else
import UIKit
#endif

public enum HeadingRenderer {

    /// Render a heading's displayed text.
    ///
    /// - Parameters:
    ///   - level: ATX heading level, 1–6.
    ///   - suffix: the raw text after the `#` markers (may begin with a
    ///     space, may be empty). The renderer trims surrounding
    ///     whitespace to produce the displayed text.
    ///   - bodyFont: the base font. Heading levels scale up from this.
    public static func render(
        level: Int,
        suffix: String,
        bodyFont: PlatformFont,
        theme: Theme = .shared
    ) -> NSAttributedString {
        // Architectural invariant: the rendered string must contain ONLY
        // the displayed heading text. It MUST NOT contain `#` characters.
        //
        // Strip ONLY leading spaces/tabs (the required separator after
        // the `#` markers in CommonMark). Trailing whitespace is preserved
        // so the rendered length always matches the logical suffix length
        // minus the leading separator — otherwise editing-offset →
        // suffix-offset mapping breaks as soon as the user types a
        // trailing space into a heading (the document grows but the
        // rendered storage doesn't, stranding the cursor past the end).
        // See EditingOps.insertIntoBlock(.heading).
        var displayed = Substring(suffix)
        while let first = displayed.first, first == " " || first == "\t" {
            displayed = displayed.dropFirst()
        }

        let font = headingFont(level: level, bodyFont: bodyFont, theme: theme)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: PlatformColor.label
        ]
        return InlineRenderer.render(
            [.text(String(displayed))],
            baseAttributes: attrs,
            theme: theme
        )
    }

    /// Heading font: derive a bold heading-scaled font from the body
    /// font. Levels 1–6 map to progressively smaller sizes.
    ///
    /// Phase 7.3: scale factors come from `theme.headingFontScale(for:)`
    /// instead of a hardcoded switch. Default-theme values
    /// (`[2.0, 1.7, 1.4, 1.2, 1.1, 1.05]`) match the pre-theme constants
    /// byte-for-byte — source-mode `NotesTextProcessor` still uses its
    /// own hardcoded copy (that pipeline dies in Phase 4, per REFACTOR_PLAN).
    private static func headingFont(
        level: Int,
        bodyFont: PlatformFont,
        theme: Theme = .shared
    ) -> PlatformFont {
        let baseSize = bodyFont.pointSize
        let scale = theme.headingFontScale(for: level)
        let size = baseSize * scale
        #if os(OSX)
        let descriptor = bodyFont.fontDescriptor.withSymbolicTraits(.bold)
        return PlatformFont(descriptor: descriptor, size: size) ?? .boldSystemFont(ofSize: size)
        #else
        let descriptor = bodyFont.fontDescriptor.withSymbolicTraits(.traitBold)
            ?? bodyFont.fontDescriptor
        return PlatformFont(descriptor: descriptor, size: size)
        #endif
    }
}
